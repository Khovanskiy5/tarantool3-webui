--
-- Shared helper for resolving in-tree paths and wiring package.path so
-- the backend modules become require'able without `tt rocks install`.
--
-- Every other helper requires this one first; the side effect of
-- the module load is what makes `require('webui')` work in CI.
--

local fio = require('fio')

-- Compute the repository root from this file's own path. The chain of
-- dirname() calls matches `<repo>/backend/test/helpers/paths.lua` ->
-- `<repo>`. Pinning it via debug.getinfo keeps the helper portable
-- across CI working directories.
local source_path = debug.getinfo(1, 'S').source:sub(2)
local repo_root = fio.abspath(
    fio.dirname(fio.dirname(fio.dirname(fio.dirname(source_path))))
)

local M = {
    repo_root        = repo_root,
    backend_dir      = repo_root .. '/backend',
    rocks_share      = repo_root .. '/.rocks/share/tarantool',
    rocks_lib        = repo_root .. '/.rocks/lib/tarantool',
    docker_dir       = repo_root .. '/docker',
    docker_configs   = repo_root .. '/docker/configs',
    docker_haproxy   = repo_root .. '/docker/haproxy',
    docker_compose   = repo_root .. '/docker/docker-compose.yml',
    cluster_seed_dir = repo_root .. '/docker/configs/cluster',
    tools_dir        = repo_root .. '/tools',
}

-- Augment package.path / package.cpath so:
--   * backend/webui/* and backend/internal/* are require'able
--   * any externally-installed rocks in .rocks/ are also found
-- Calling this is idempotent; we only prepend prefixes that are not
-- already at the start of the path.
local function prepend_unique(env, prefix)
    if string.sub(env, 1, #prefix) == prefix then return env end
    return prefix .. env
end

local prefixes_added = false
function M.setup_package_path()
    if prefixes_added then return end
    local pp = ';' .. M.backend_dir .. '/?.lua;'
            .. M.backend_dir .. '/?/init.lua;'
            .. M.rocks_share .. '/?.lua;'
            .. M.rocks_share .. '/?/init.lua;'
    package.path = prepend_unique(package.path, pp)

    local pcp = ';' .. M.rocks_lib .. '/?.so;'
             .. M.rocks_lib .. '/?.dylib;'
    package.cpath = prepend_unique(package.cpath, pcp)
    prefixes_added = true
end

return M
