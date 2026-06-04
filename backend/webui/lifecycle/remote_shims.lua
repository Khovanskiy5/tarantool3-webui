--
-- net.box remote shims.
--
-- Every entry here installs a global `webui_*_remote` function that
-- a follower instance can `:call(...)` against the leader via net.box.
-- They live in the global namespace because net.box's `:call(name)`
-- resolves `name` through _G, not through Lua module tables.
--
-- The installers themselves are kept dumb on purpose: a thin pcall
-- around require() of the module that owns the actual logic, then a
-- delegating call. Heavy lifting (RBAC, deny-list re-check, audit)
-- belongs in the owning module, not here.
--
-- One exception: `webui_config_reload_remote` delegates to Tarantool's
-- native `config:reload()` rather than a role module — the role does
-- not own config reload.
--
-- Called exactly once during M.start (right after storage bootstrap
-- so the spaces the shims poke at already exist). Idempotent — each
-- rawset just overwrites the previous value on a role reload.
--

local M = {}

function M.install()
    -- Expose the leader-only session creator over net.box so
    -- followers can forward `/api/auth/login` writes. Safe to call
    -- on every instance — only the leader's INSERT actually
    -- succeeds; followers raise READONLY locally.
    local sess_remote_ok, sess_mod = pcall(require, 'webui.auth.session')
    if sess_remote_ok and type(sess_mod.install_remote) == 'function' then
        sess_mod.install_remote()
    end

    -- Expose the vshard bootstrap helper over net.box for the same
    -- reason: when the SPA calls `bootstrapVshard(group)` from a
    -- follower, the resolver routes the call to a router-flagged
    -- peer via this function.
    local vsh_ok, vsh_mod = pcall(require, 'webui.graphql.resolvers.vshard')
    if vsh_ok and type(vsh_mod.install_remote) == 'function' then
        vsh_mod.install_remote()
    end

    -- Expose the audit-log writer over net.box so a follower can
    -- forward `_webui_audit` inserts to the leader (the space is
    -- replicated; direct insert on a follower raises READONLY).
    -- The local M.record falls back to this when box.info.ro is
    -- true; here we wire the receiver side.
    rawset(_G, 'webui_audit_record_remote', function(entry)
        local ok_aud, aud_mod = pcall(require, 'webui.audit.log')
        if not ok_aud then return nil, 'audit module unavailable' end
        local ok, res = pcall(aud_mod.record_local, entry)
        if not ok then return nil, tostring(res) end
        if res == nil then return nil, 'insert returned nil' end
        return { id = res.id, ts = res.ts, action = res.action }
    end)

    -- Expose data-explorer tuple mutations over net.box so a
    -- follower-served request can be forwarded to the leader. The
    -- resolver on the follower validates RBAC + sensitive-space
    -- deny-list BEFORE forwarding; the receiver re-checks the
    -- deny-list and runs `box.space[X]:insert/replace/update/delete`
    -- under the peer-cookie user (already granted CRUD on user
    -- spaces by the role registration).
    rawset(_G, 'webui_data_mutation_remote', function(op, space, payload, ctx)
        local ok_mod, mut = pcall(require,
            'webui.graphql.resolvers.data_mutations')
        if not ok_mod then return { _error = 'data_mutations module unavailable' } end
        return mut.remote_entry(op, space, payload, ctx)
    end)

    -- DDL receiver for the same forward-to-leader path. createSpace /
    -- dropSpace / alterSpace / createIndex / dropIndex on a follower
    -- routes here on the elected leader.
    rawset(_G, 'webui_space_mutation_remote', function(op, payload, ctx)
        local ok_mod, mut = pcall(require,
            'webui.graphql.resolvers.data_mutations')
        if not ok_mod then return { _error = 'data_mutations module unavailable' } end
        return mut.space_remote_entry(op, payload, ctx)
    end)

    -- SQL workbench snippet save/delete forwarder (Phase 3 Task 3.4).
    rawset(_G, 'webui_saved_query_remote', function(op, payload, ctx)
        local ok_mod, sq = pcall(require,
            'webui.graphql.resolvers.saved_queries')
        if not ok_mod then return { _error = 'saved_queries module unavailable' } end
        return sq.remote_entry(op, payload, ctx)
    end)

    -- Log tail forwarder. The /api/logs handler on instance A
    -- proxies through this shim when the operator asks for instance
    -- B's log via `?instance=B` — keeps a single HTTP entry point
    -- and reuses the peer pool's connections instead of opening a
    -- fresh one per request. The receiver runs `api.logs.tail`
    -- locally and returns the plain result table.
    rawset(_G, 'webui_logs_tail_remote', function(query)
        local ok_mod, logs_api = pcall(require, 'webui.api.logs')
        if not ok_mod then
            return { ok = false, code = 'INTERNAL',
                     message = 'api.logs module unavailable' }
        end
        return logs_api.tail(query)
    end)

    -- Expose the dead-letter truncate over net.box. clearDeadLetter
    -- from the SPA lands on a random instance through round-robin;
    -- the leader is the only one that can actually truncate the
    -- replicated `_webui_webhook_dead_letter` space.
    rawset(_G, 'webui_webhook_dead_letter_clear_remote', function()
        local ok_sto, sto_mod = pcall(require, 'webui.storage.spaces')
        if not ok_sto then return nil, 'storage module unavailable' end
        local space = sto_mod.webhook_dead_letter()
        if space == nil then return nil, 'dead-letter space missing' end
        local count = space:count() or 0
        local trunc_ok, trunc_err = pcall(function() space:truncate() end)
        if not trunc_ok then return nil, tostring(trunc_err) end
        return { cleared = count }
    end)

    -- Re-bootstrap this instance: wipe WAL/snap and trigger a process
    -- exit so Docker's restart policy launches a fresh process that
    -- bootstraps clean from healthy peers. Used by the rebootstrap
    -- GraphQL mutation to fan out a recovery action to a specific
    -- follower (queue owner refused — see api.diagnostics).
    rawset(_G, 'webui_rebootstrap_remote', function()
        local ok_mod, diag = pcall(require, 'webui.api.diagnostics')
        if not ok_mod then return { err = 'diagnostics module unavailable' } end
        local fake_req = { request_id = 'peer:rebootstrap' }
        local resp = diag.rebootstrap_handler(fake_req)
        if type(resp) ~= 'table' then return { err = 'bad response' } end
        local body_ok, body = pcall(require('json').decode, resp.body or '')
        if not body_ok or type(body) ~= 'table' then
            return { err = 'rebootstrap response unparseable',
                     status = resp.status }
        end
        if body.error then
            return { err = body.error.code or 'UNKNOWN',
                     message = body.error.message,
                     status = resp.status }
        end
        return {
            ok            = body.ok == true,
            instance      = body.instance,
            deleted_count = body.deleted_count,
            message       = body.message,
            status        = resp.status,
        }
    end)

    -- Run the clean rebootstrap orchestrator ON THIS instance. The
    -- recovery executor calls this on the RW leader so the whole
    -- expel → wipe → re-add → verify flow runs on a node that survives
    -- the target's wipe (the request itself may have landed anywhere,
    -- including the orphan target, via HAProxy round-robin). Heavy
    -- lifting lives in webui.recovery.identity_reset.
    rawset(_G, 'webui_identity_reset_remote', function(args)
        local ok_ir, ir = pcall(require, 'webui.recovery.identity_reset')
        if not ok_ir then return { err = 'identity_reset module unavailable' } end
        local target = type(args) == 'table' and args.target or nil
        return ir.run({ target_alias = target })
    end)

    -- Graceful restart (FO-12): drain the synchro queue (no-op on a
    -- follower) and exit so Docker's restart policy respins a fresh
    -- process that rejoins as a follower. Unlike rebootstrap this does
    -- NOT wipe WAL/snap — it is an ordinary restart used by the rolling
    -- orchestrator. The exit is deferred a beat so this RPC reply flushes
    -- to the coordinator before the connection drops.
    rawset(_G, 'webui_graceful_restart_remote', function()
        local fiber = require('fiber')
        fiber.create(function()
            fiber.self():name('webui_graceful_restart', { truncate = true })
            fiber.sleep(0.3)
            pcall(function()
                require('webui.failover.drain').drain_synchro_queue(3)
            end)
            os.exit(0)
        end)
        return { ok = true, message = 'graceful restart scheduled' }
    end)

    -- Restart the supervised failover agent fiber on this peer (RC-7).
    -- The `restart_failover` recovery action fans this out to the
    -- selected instances so a wedged agent loop is rebuilt from the
    -- instance's own running config (STATE.config.failover) — no config
    -- edit, no data touched. Stop+start drops and re-acquires the
    -- coordinator lease; the coordinator re-elects on the next tick.
    rawset(_G, 'webui_restart_failover_remote', function()
        local st_ok, lstate = pcall(require, 'webui.lifecycle.state')
        if not st_ok then return { err = 'lifecycle state unavailable' } end
        local fo_ok, fo = pcall(require, 'webui.failover')
        if not fo_ok then return { err = 'failover module unavailable' } end
        local STATE = lstate.STATE
        local fo_cfg = (STATE and STATE.config or {}).failover or {}
        if fo_cfg.agent ~= true then
            return { ok = false, err = 'failover agent not enabled here' }
        end
        local started, err = fo.restart(fo_cfg)
        if started == true then
            STATE.failover = fo
            return { ok = true }
        end
        STATE.failover = nil
        return { ok = false, err = tostring(err or 'restart failed') }
    end)

    -- Mirror the committed cluster YAML to the on-disk file on this
    -- peer. The two-phase commit pipeline fans this call out to every
    -- instance after the etcd put lands so the file (recovery snapshot)
    -- always matches the etcd source of truth. Atomic write semantics
    -- live in webui.config_store.file_writer.
    rawset(_G, 'webui_config_file_write_remote', function(payload)
        if type(payload) ~= 'string' or #payload == 0 then
            return { err = 'EMPTY_PAYLOAD' }
        end
        local ok_mod, fw = pcall(require, 'webui.config_store.file_writer')
        if not ok_mod then return { err = 'file_writer unavailable' } end
        local ok, res = fw.write_local(payload)
        if ok == nil then return { err = tostring(res) } end
        return { path = res }
    end)

    -- Expose _webui_prepared replace / delete over net.box. The
    -- two-phase commit pipeline stores its prepared bundle there;
    -- a follower forwards prepare() / commit() writes through these
    -- shims so the prepared_id is reachable from any peer that the
    -- round-robin balancer later picks.
    rawset(_G, 'webui_prepared_put_remote', function(entry)
        if type(entry) ~= 'table' or type(entry.id) ~= 'string' then
            return { err = 'bad entry' }
        end
        local ok_sto, sto_mod = pcall(require, 'webui.storage.spaces')
        if not ok_sto then return { err = 'storage module unavailable' } end
        local space = sto_mod.prepared()
        if space == nil then return { err = 'prepared space missing' } end
        local repl_ok, repl_err = pcall(function()
            space:replace({
                entry.id,
                entry.yaml,
                entry.user or '',
                entry.ts,
                entry.expires_at,
            })
        end)
        if not repl_ok then return { err = tostring(repl_err) } end
        return { id = entry.id }
    end)
    rawset(_G, 'webui_prepared_delete_remote', function(id)
        if type(id) ~= 'string' then return { err = 'bad id' } end
        local ok_sto, sto_mod = pcall(require, 'webui.storage.spaces')
        if not ok_sto then return { err = 'storage module unavailable' } end
        local space = sto_mod.prepared()
        if space == nil then return { err = 'prepared space missing' } end
        local del_ok, del_err = pcall(function() space:delete({ id }) end)
        if not del_ok then return { err = tostring(del_err) } end
        return { deleted = true }
    end)

    -- Forward-to-leader shims for the _webui_failover_commands
    -- journal (Task 5.13). A follower calling commands.record from
    -- a GraphQL resolver lands here on the leader so the replicated
    -- sync space sees a single writer.
    rawset(_G, 'webui_failover_commands_write_remote', function(row)
        if type(row) ~= 'table' then return { err = 'bad row' } end
        local ok_sto, sto_mod = pcall(require, 'webui.storage.spaces')
        if not ok_sto then return { err = 'storage module unavailable' } end
        local space = sto_mod.failover_commands()
        if space == nil then return { err = 'failover_commands missing' } end
        local ok, tup = pcall(function() return space:insert(row) end)
        if not ok then return { err = tostring(tup) } end
        return { id = tup[1] }
    end)
    rawset(_G, 'webui_failover_commands_complete_remote',
        function(id, status, error_reason, completed_at)
            if type(id) ~= 'number' then return { err = 'bad id' } end
            local ok_sto, sto_mod = pcall(require, 'webui.storage.spaces')
            if not ok_sto then return { err = 'storage module unavailable' } end
            local space = sto_mod.failover_commands()
            if space == nil then return { err = 'failover_commands missing' } end
            local ok, err = pcall(function()
                space:update({ id }, {
                    { '=', 'status',       status or 'success' },
                    { '=', 'completed_at', completed_at or 0 },
                    { '=', 'error_reason', error_reason },
                })
            end)
            if not ok then return { err = tostring(err) } end
            return { updated = true }
        end)

    -- Force the Tarantool native `config:reload()` on this peer. The
    -- twophase commit pipeline fans this call out across `peers.list()`
    -- after the new cluster YAML lands in etcd + on every peer's local
    -- file (via `webui_config_file_write_remote`). Without an explicit
    -- reload each peer would only refresh on its own polling tick,
    -- which makes the bootstrap UX feel "did anything happen?" — the
    -- reload makes `box.cfg{replication = ...}` apply immediately.
    --
    -- Returns `{ ok = true, status = <config.info().status> }` on
    -- success or `{ err = <reason> }` on failure. Receiver delegates
    -- to Tarantool's native module, not the role.
    rawset(_G, 'webui_config_reload_remote', function()
        local log_ok, lu = pcall(require, 'webui.log_util')
        local lg = log_ok and lu.with_tag('config.reload.remote') or nil
        local t0 = (require('fiber')).time()
        if lg then lg.debug('called', { at = t0 }) end

        local ok_cfg, cfg = pcall(require, 'config')
        if not ok_cfg then
            if lg then lg.warn('failed', { err = 'config module unavailable' }) end
            return { err = 'config module unavailable' }
        end
        local ok_rl, err = pcall(function() cfg:reload() end)
        if not ok_rl then
            if lg then lg.warn('failed', { err = tostring(err) }) end
            return { err = tostring(err) }
        end
        local info = (cfg.info and cfg:info()) or {}
        local elapsed_ms = math.floor(((require('fiber')).time() - t0) * 1000)
        if lg then
            lg.info('ok', { status = info.status, elapsed_ms = elapsed_ms })
        end
        return { ok = true, status = info.status, elapsed_ms = elapsed_ms }
    end)

    -- Failsafe acceptance (Task FO-16). A leader that lost the DCS asks
    -- each peer "do you still defer to me?". A peer accepts iff it is
    -- itself read-only — i.e. NOT a competing writer. If every peer is
    -- read-only and reachable, the asker staying read-write keeps a
    -- single writer (no other partition can hold a majority). The
    -- leader_alias arg is accepted for logging/forward-compat; the
    -- verdict only depends on our own write status.
    rawset(_G, 'webui_failsafe_accept', function(_leader_alias)
        local ro = true
        if rawget(_G, 'box') ~= nil and box.info ~= nil then
            ro = box.info.ro == true
        end
        return { accepted = ro }
    end)
end

return M
