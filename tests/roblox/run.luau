export type Case = { name: string, run: () -> () }
export type Failure = { name: string, message: string }

-- runs one engine spec's cases. scripts/roblox_cloud_test.py gives every spec
-- under tests/roblox a task of its own, so this never requires a spec itself:
-- whatever it required would be bundled into every task
return function(cases: { Case })
  local passed = 0
  local failed = 0
  local failures: { Failure } = {}
  local lines = {}

  for _, case in cases do
    local ok, err = pcall(case.run)

    if ok then
      passed += 1
      table.insert(lines, `[PASS] {case.name}`)
    else
      failed += 1
      table.insert(failures, { name = case.name, message = tostring(err) })
      table.insert(lines, `[FAIL] {case.name}\n       {tostring(err)}`)
    end
  end

  table.insert(lines, "")
  table.insert(lines, `{passed} passed, {failed} failed`)

  return passed, failed, table.concat(lines, "\n"), failures
end
