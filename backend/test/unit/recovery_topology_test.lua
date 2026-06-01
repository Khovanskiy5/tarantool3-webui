local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local topo = require('webui.recovery.topology_fix')

local g = t.group('recovery.topology_fix')

-- Minimal cluster config with three peers.
local function sample_cfg(uris)
    local instances = {}
    for alias, uri in pairs(uris) do
        instances[alias] = {
            iproto = {
                advertise = { peer = { uri = uri } },
            },
        }
    end
    return {
        groups = {
            default = {
                replicasets = {
                    ['rs-1'] = { instances = instances },
                },
            },
        },
    }
end

g.test_walk_declared_lists_all_aliases = function()
    local cfg = sample_cfg({
        ['tt-1'] = 'tt-1:3301',
        ['tt-2'] = 'tt-2:3301',
        ['tt-3'] = 'tt-3:3301',
    })
    local out = topo.walk_declared(cfg)
    t.assert_equals(#out, 3)
    -- Sorted by alias.
    t.assert_equals(out[1].alias, 'tt-1')
    t.assert_equals(out[1].declared_uri, 'tt-1:3301')
    t.assert_equals(out[3].alias, 'tt-3')
end

g.test_walk_declared_emits_nil_uri_for_missing_advertise = function()
    local cfg = {
        groups = {
            default = {
                replicasets = {
                    ['rs-1'] = {
                        instances = {
                            ['tt-1'] = {},  -- no iproto block at all
                        },
                    },
                },
            },
        },
    }
    local out = topo.walk_declared(cfg)
    t.assert_equals(#out, 1)
    t.assert_equals(out[1].declared_uri, nil)
end

g.test_cross_check_suggests_fix_when_observed_differs_and_reachable = function()
    local declared = {
        { alias = 'tt-1', declared_uri = 'old-host:3301' },
    }
    local observed = {
        ['tt-1'] = { uri = 'new-host:3301', reachable = true },
    }
    local out = topo.cross_check(declared, observed)
    t.assert_equals(out[1].suggestion, 'new-host:3301')
    t.assert_equals(out[1].reachable, true)
end

g.test_cross_check_no_suggestion_when_observed_unreachable = function()
    -- Suggesting an unreachable URI would replace one dead
    -- pointer with another. The cross-check must hold off.
    local declared = {
        { alias = 'tt-1', declared_uri = 'old-host:3301' },
    }
    local observed = {
        ['tt-1'] = { uri = 'new-host:3301', reachable = false },
    }
    local out = topo.cross_check(declared, observed)
    t.assert_equals(out[1].suggestion, nil)
end

g.test_cross_check_no_suggestion_when_uris_match = function()
    local declared = {
        { alias = 'tt-1', declared_uri = 'tt-1:3301' },
    }
    local observed = {
        ['tt-1'] = { uri = 'tt-1:3301', reachable = true },
    }
    local out = topo.cross_check(declared, observed)
    t.assert_equals(out[1].suggestion, nil)
end

g.test_cross_check_handles_missing_observed_alias = function()
    local declared = {
        { alias = 'ghost-peer', declared_uri = 'ghost:3301' },
    }
    -- ghost-peer is in the YAML but not in the running pool.
    -- We have no observed URI to compare against — leave the
    -- row unchanged so the operator sees the declared state
    -- and can decide.
    local out = topo.cross_check(declared, {})
    t.assert_equals(out[1].suggestion, nil)
    t.assert_equals(out[1].observed_uri, nil)
    t.assert_equals(out[1].reachable, false)
end
