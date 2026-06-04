local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;'
            .. repo_root .. '/backend/?/init.lua;'
            .. package.path

local yaml = require('yaml')
local yaml_patch = require('webui.config_store.yaml_patch')

-- A small, comment-heavy cluster config in block style, mirroring what
-- operators actually hand-write and what the config editor renders.
local function sample()
    return table.concat({
        '# Topology: one replicaset, three peers.',
        'groups:',
        '  default:',
        '    replicasets:',
        '      rs-1:',
        '        instances:',
        '          tt-1:        # the bootstrap leader',
        '            iproto:',
        '              advertise:',
        '                peer:',
        '                  uri: tt-1:3301',
        '          tt-3:',
        '            iproto:',
        '              advertise:',
        '                peer:',
        '                  uri: tt-3:3301',
        '',
    }, '\n')
end

local function inst_path(name, ...)
    local p = { 'groups', 'default', 'replicasets', 'rs-1', 'instances', name }
    for _, k in ipairs({ ... }) do table.insert(p, k) end
    return p
end

-- ── set_field: insert a missing leaf (creates parent section) ────────

local g = t.group('config_store.yaml_patch.set_field')

g.test_inserts_leaf_and_missing_parent_section = function()
    local raw = sample()
    local out, status = yaml_patch.set_field(
        raw, inst_path('tt-3', 'database', 'instance_uuid'), 'uuid-xyz')
    t.assert_equals(status, 'inserted')
    local decoded = yaml.decode(out)
    t.assert_equals(
        decoded.groups.default.replicasets['rs-1']
            .instances['tt-3'].database.instance_uuid,
        'uuid-xyz')
end

g.test_insert_preserves_comments_and_order = function()
    local raw = sample()
    local out = yaml_patch.set_field(
        raw, inst_path('tt-3', 'database', 'instance_uuid'), 'uuid-xyz')
    -- Every comment and the leader's inline comment survive verbatim.
    t.assert_str_contains(out, '# Topology: one replicaset, three peers.')
    t.assert_str_contains(out, 'tt-1:        # the bootstrap leader')
    -- The untouched instance is byte-for-byte intact.
    t.assert_str_contains(out, '                  uri: tt-1:3301')
    -- The inserted block is indented as a child of tt-3.
    t.assert_str_contains(out, '            database:')
    t.assert_str_contains(out, '              instance_uuid: uuid-xyz')
end

g.test_only_touched_lines_change = function()
    local raw = sample()
    local out = yaml_patch.set_field(
        raw, inst_path('tt-3', 'database', 'instance_uuid'), 'uuid-xyz')
    -- The output is the input plus exactly two inserted lines.
    local function count_lines(s) local n = 0
        for _ in (s .. '\n'):gmatch('(.-)\n') do n = n + 1 end return n end
    t.assert_equals(count_lines(out), count_lines(raw) + 2)
end

g.test_rewrites_existing_leaf = function()
    local raw = sample() .. '          tt-9:\n            database:\n'
        .. '              instance_uuid: old\n'
    local out, status = yaml_patch.set_field(
        raw, inst_path('tt-9', 'database', 'instance_uuid'), 'new')
    t.assert_equals(status, 'set')
    t.assert_str_contains(out, 'instance_uuid: new')
    t.assert_not_str_contains(out, 'instance_uuid: old')
end

g.test_unchanged_when_value_matches = function()
    local raw = sample() .. '          tt-9:\n            database:\n'
        .. '              instance_uuid: keep\n'
    local out, status = yaml_patch.set_field(
        raw, inst_path('tt-9', 'database', 'instance_uuid'), 'keep')
    t.assert_equals(status, 'unchanged')
    t.assert_equals(out, raw)
end

g.test_preserves_sibling_database_keys = function()
    local raw = sample() .. '          tt-9:\n            database:\n'
        .. '              mode: rw\n'
    local out = yaml_patch.set_field(
        raw, inst_path('tt-9', 'database', 'instance_uuid'), 'uuid-xyz')
    local db = yaml.decode(out).groups.default.replicasets['rs-1']
        .instances['tt-9'].database
    t.assert_equals(db.mode, 'rw')
    t.assert_equals(db.instance_uuid, 'uuid-xyz')
end

g.test_error_when_root_key_absent = function()
    local out, err = yaml_patch.set_field('foo: bar\n',
        { 'groups', 'default' }, 'x')
    t.assert_equals(out, nil)
    t.assert_str_contains(err, 'no anchor')
end

g.test_rejects_empty_path = function()
    local out, err = yaml_patch.set_field('a: 1\n', {}, 'x')
    t.assert_equals(out, nil)
    t.assert_str_contains(err, 'non-empty')
end

g.test_keeps_trailing_newline_state = function()
    local with_nl = yaml_patch.set_field(sample(),
        inst_path('tt-3', 'database', 'instance_uuid'), 'u')
    t.assert_equals(with_nl:sub(-1), '\n')
    local no_nl_src = 'groups:\n  default:\n    x: 1' -- no trailing newline
    local out = yaml_patch.set_field(no_nl_src, { 'groups', 'default', 'y' }, '2')
    t.assert_not_equals(out:sub(-1), '\n')
end

-- ── replace_value ───────────────────────────────────────────────────

local g2 = t.group('config_store.yaml_patch.replace_value')

g2.test_replaces_verbatim = function()
    local out, n = yaml_patch.replace_value('uri: tt-1:3301\n',
        'tt-1:3301', 'tt-9:3301')
    t.assert_equals(n, 1)
    t.assert_str_contains(out, 'uri: tt-9:3301')
end

g2.test_no_pattern_magic = function()
    -- A value with Lua-magic chars must match literally, not as a pattern.
    local out, n = yaml_patch.replace_value('k: a.b+c\n', 'a.b+c', 'x')
    t.assert_equals(n, 1)
    t.assert_str_contains(out, 'k: x')
end

g2.test_percent_in_replacement = function()
    local out = yaml_patch.replace_value('k: v\n', 'v', '100%')
    t.assert_str_contains(out, 'k: 100%')
end

-- ── find_instance_path ──────────────────────────────────────────────

local g3 = t.group('config_store.yaml_patch.find_instance_path')

g3.test_finds_existing_instance = function()
    local parsed = yaml.decode(sample())
    t.assert_equals(yaml_patch.find_instance_path(parsed, 'tt-3'),
        { 'groups', 'default', 'replicasets', 'rs-1', 'instances', 'tt-3' })
end

g3.test_nil_for_absent_instance = function()
    local parsed = yaml.decode(sample())
    t.assert_equals(yaml_patch.find_instance_path(parsed, 'tt-404'), nil)
end

g3.test_nil_for_non_table = function()
    t.assert_equals(yaml_patch.find_instance_path('nope', 'tt-1'), nil)
end

-- ── end-to-end: rebootstrap identity-pin shape ──────────────────────

local g4 = t.group('config_store.yaml_patch.identity_pin')

-- ── render: formatting-preserving structural merge ──────────────────

local g5 = t.group('config_store.yaml_patch.render')

-- Apply a mutator to the decoded tree, render against the raw, and return
-- the new raw plus its decoded form. Asserts the core invariant: render
-- output ALWAYS decodes exactly to the new tree.
local function render_after(raw, mutate)
    local old = yaml.decode(raw)
    local new = yaml.decode(raw) -- independent copy
    mutate(new)
    local out = yaml_patch.render(raw, old, new)
    local decoded = yaml.decode(out)
    t.assert_equals(decoded, new) -- HARD invariant
    return out, decoded
end

g5.test_scalar_change_preserves_all_comments = function()
    local raw = sample()
    local out = render_after(raw, function(c)
        c.groups.default.replicasets['rs-1'].instances['tt-1']
            .iproto.advertise.peer.uri = 'tt-1:4400'
    end)
    -- Comment count unchanged; only the one URI line rewritten.
    t.assert_str_contains(out, '# Topology: one replicaset, three peers.')
    t.assert_str_contains(out, 'tt-1:        # the bootstrap leader')
    -- host:port stays an unquoted plain scalar (house style).
    t.assert_str_contains(out, 'uri: tt-1:4400')
    t.assert_not_str_contains(out, 'uri: tt-1:3301')
end

g5.test_add_instance_keeps_existing_comments = function()
    local raw = sample()
    local out = render_after(raw, function(c)
        c.groups.default.replicasets['rs-1'].instances['tt-9'] = {
            iproto = { advertise = { peer = { uri = 'tt-9:3301' } } },
        }
    end)
    t.assert_str_contains(out, '# Topology: one replicaset, three peers.')
    t.assert_str_contains(out, 'tt-1:        # the bootstrap leader')
    -- The untouched tt-3 block is byte-identical.
    t.assert_str_contains(out, '                  uri: tt-3:3301')
    t.assert_str_contains(out, 'tt-9:')
end

g5.test_remove_instance_drops_block_keeps_siblings = function()
    local raw = sample()
    local out = render_after(raw, function(c)
        c.groups.default.replicasets['rs-1'].instances['tt-3'] = nil
    end)
    t.assert_not_str_contains(out, 'uri: tt-3:3301')
    t.assert_str_contains(out, 'tt-1:        # the bootstrap leader')
    t.assert_str_contains(out, '# Topology: one replicaset, three peers.')
end

g5.test_multikey_change_invariant_holds = function()
    -- A failover-mode-style sweep: add replication block + per-instance
    -- election_mode + a new top-level section.
    local raw = sample()
    render_after(raw, function(c)
        c.replication = { failover = 'supervised' }
        local insts = c.groups.default.replicasets['rs-1'].instances
        insts['tt-1'].replication = { election_mode = 'candidate' }
        insts['tt-3'].replication = { election_mode = 'voter' }
    end)
    -- render_after already asserts decoded == new for every mutation.
end

g5.test_list_change_is_valid = function()
    local raw = 'svc:\n  roles:\n  - a\n  - b\n'
    local out = render_after(raw, function(c) c.svc.roles = { 'a', 'b', 'c' } end)
    t.assert_str_contains(out, 'c')
end

g5.test_type_change_scalar_to_map = function()
    local raw = 'k: scalar\n'
    render_after(raw, function(c) c.k = { nested = 'val' } end)
end

g5.test_fallback_on_flow_style_still_valid = function()
    -- Flow-style source can't be line-merged; render must still return a
    -- valid document that decodes to the new tree (via re-encode).
    local raw = "--- {'a': 1, 'b': 2}\n...\n"
    local old = yaml.decode(raw)
    local new = yaml.decode(raw); new.b = 3
    local out = yaml_patch.render(raw, old, new)
    t.assert_equals(yaml.decode(out), new)
end

g5.test_inserted_block_uses_house_style = function()
    -- New sequence dashes sit at the key's indent and fold the first key
    -- onto the dash line; host:port stays unquoted.
    local raw = sample()
    local out = render_after(raw, function(c)
        c.groups.default.replicasets['rs-1'].instances['tt-9'] = {
            iproto = { listen = { { uri = '0.0.0.0:3301' } } },
        }
    end)
    t.assert_str_contains(out, '              listen:\n              - uri: 0.0.0.0:3301')
end

g5.test_quoting_rules = function()
    -- A number-like string is quoted (keeps string type); a host:port and
    -- a plain token are not.
    local raw = 'svc:\n  a: keep\n'
    local out = render_after(raw, function(c)
        c.svc.numlike = '3301'   -- must round-trip as a string
        c.svc.uri = 'h:3301'     -- bare colon → plain scalar
        c.svc.word = 'super'
    end)
    t.assert_str_contains(out, "numlike: '3301'")
    t.assert_str_contains(out, 'uri: h:3301')
    t.assert_str_contains(out, 'word: super')
end

g5.test_noop_change_is_identity = function()
    local raw = sample()
    local old = yaml.decode(raw)
    local out = yaml_patch.render(raw, old, yaml.decode(raw))
    t.assert_equals(out, raw) -- nothing changed -> byte-identical
end

g4.test_pin_uuid_on_instance_without_database = function()
    -- Reproduces the rebootstrap pin: discover the instance path from the
    -- parsed tree, then text-patch instance_uuid into the raw config.
    local raw = sample()
    local parsed = yaml.decode(raw)
    local path = yaml_patch.find_instance_path(parsed, 'tt-3')
    t.assert_not_equals(path, nil)
    table.insert(path, 'database')
    table.insert(path, 'instance_uuid')
    local out, status = yaml_patch.set_field(raw, path, 'aaaa-bbbb')
    t.assert_equals(status, 'inserted')
    t.assert_str_contains(out, '# Topology: one replicaset, three peers.')
    t.assert_equals(
        yaml.decode(out).groups.default.replicasets['rs-1']
            .instances['tt-3'].database.instance_uuid,
        'aaaa-bbbb')
end
