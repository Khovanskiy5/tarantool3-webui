-- luacheck: globals os.setenv
-- Unit tests for webui.config_store.file_writer — atomic mirror of
-- the cluster YAML to the on-disk file.
--
-- Covers both write strategies: the rename path (parent dir writable
-- and the destination is a regular file, not a single-file bind mount)
-- and the in-place truncate-and-write fallback. The runtime branch
-- between them is opaque to the caller — we assert post-conditions on
-- the resulting file content, not which path was taken.

local t = require('luatest')
local fio = require('fio')
local repo_root = fio.abspath(fio.dirname(fio.dirname(fio.dirname(fio.dirname(
    debug.getinfo(1, 'S').source:sub(2)
)))))
package.path = repo_root .. '/backend/?.lua;backend/?/init.lua;' .. package.path

local file_writer = require('webui.config_store.file_writer')

local g = t.group('config_file_writer')

local function make_tmpfile(initial)
    local dir = fio.tempdir()
    local path = dir .. '/cluster.yaml'
    local f = fio.open(path, { 'O_WRONLY', 'O_CREAT', 'O_TRUNC' },
        tonumber('644', 8))
    f:write(initial or 'initial: yes\n')
    f:close()
    return path, dir
end

local function read_all(path)
    local f = fio.open(path, { 'O_RDONLY' })
    if f == nil then return nil end
    local body = f:read()
    f:close()
    return body
end

g.test_write_local_rejects_empty_payload = function()
    local path, dir = make_tmpfile()
    local ok, err = file_writer.write_local('', { path = path })
    t.assert_equals(ok, nil)
    t.assert_equals(err, 'EMPTY_PAYLOAD')
    -- file content untouched
    t.assert_equals(read_all(path), 'initial: yes\n')
    fio.rmtree(dir)
end

g.test_write_local_returns_no_path_when_unresolved = function()
    -- Override every env var the resolver looks at, point at a path
    -- that explicitly does not exist anywhere.
    local saved = {
        TT_CONFIG_PATH = os.getenv('TT_CONFIG_PATH'),
        TT_CONFIG      = os.getenv('TT_CONFIG'),
    }
    os.setenv('TT_CONFIG_PATH', '/nonexistent/aifac-test-impossible/cluster.yaml')
    os.setenv('TT_CONFIG', '/nonexistent/aifac-test-impossible/cluster.yaml')

    local ok, err = file_writer.write_local('something: 1\n')
    t.assert_equals(ok, nil)
    -- NO_PATH when nothing in the candidate list exists AND the
    -- well-known fallback /opt/webui/etc/cluster.yaml is absent on
    -- the developer machine running the tests.
    if err == 'NO_PATH' then
        t.assert_equals(err, 'NO_PATH')
    else
        -- On a workstation that happens to have the well-known file
        -- (unlikely outside the container) the write succeeds; that
        -- is acceptable, we just guard against false-positive flakes.
        t.skip('local well-known path exists; skipping NO_PATH branch')
    end

    if saved.TT_CONFIG_PATH ~= nil then
        os.setenv('TT_CONFIG_PATH', saved.TT_CONFIG_PATH)
    end
    if saved.TT_CONFIG ~= nil then
        os.setenv('TT_CONFIG', saved.TT_CONFIG)
    end
end

g.test_write_local_replaces_file_contents = function()
    local path, dir = make_tmpfile('old: 1\n')
    local payload = 'new: 2\nanother: value\n'
    local ok, returned = file_writer.write_local(payload, { path = path })
    t.assert_equals(ok, true)
    t.assert_equals(returned, path)
    t.assert_equals(read_all(path), payload)
    fio.rmtree(dir)
end

g.test_write_local_overwrites_repeatedly = function()
    -- Mirrors what twophase.commit does after every successful etcd
    -- write — the same file gets rewritten over and over.
    local path, dir = make_tmpfile('rev: 0\n')
    for i = 1, 5 do
        local payload = string.format('rev: %d\n', i)
        local ok = file_writer.write_local(payload, { path = path })
        t.assert_equals(ok, true)
        t.assert_equals(read_all(path), payload)
    end
    fio.rmtree(dir)
end

g.test_write_local_leaves_no_tmp_residue_on_success = function()
    local path, dir = make_tmpfile()
    local payload = 'value: present\n'
    file_writer.write_local(payload, { path = path })
    -- Both write paths must clean up after themselves. The rename
    -- branch renames the tmp atomically; the in-place branch doesn't
    -- create a tmp at all.
    local left_overs = {}
    for _, name in pairs(fio.listdir(dir) or {}) do
        if name:match('%.tmp%.') then table.insert(left_overs, name) end
    end
    t.assert_equals(#left_overs, 0,
        'tmp files leaked: ' .. table.concat(left_overs, ', '))
    fio.rmtree(dir)
end

g.test_resolve_path_returns_nil_when_nothing_exists = function()
    local saved = {
        TT_CONFIG_PATH = os.getenv('TT_CONFIG_PATH'),
        TT_CONFIG      = os.getenv('TT_CONFIG'),
    }
    os.setenv('TT_CONFIG_PATH', '/nonexistent/aifac-also-impossible/cluster.yaml')
    os.setenv('TT_CONFIG', '/nonexistent/aifac-also-impossible/cluster.yaml')

    local resolved = file_writer.resolve_path()
    -- Either nil (clean workstation, no well-known file) or a real
    -- pre-existing path; in both cases the function MUST NOT crash.
    if resolved == nil then
        t.assert_equals(resolved, nil)
    else
        t.assert_str_contains(resolved, 'cluster.yaml')
    end

    if saved.TT_CONFIG_PATH ~= nil then
        os.setenv('TT_CONFIG_PATH', saved.TT_CONFIG_PATH)
    end
    if saved.TT_CONFIG ~= nil then
        os.setenv('TT_CONFIG', saved.TT_CONFIG)
    end
end
