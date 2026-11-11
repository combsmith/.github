#!/usr/bin/env bats
# sonar_list_projects must fail (not silently succeed) on malformed pages.

SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/sonarcloud-audit.sh"

@test "null components fails the listing" {
  run bash -c "source '$SCRIPT'; _sonar_get() { echo '{\"components\":null,\"paging\":{\"total\":3}}'; }; sonar_list_projects"
  [ "$status" -ne 0 ]
}

@test "missing paging.total fails the listing" {
  run bash -c "source '$SCRIPT'; _sonar_get() { echo '{\"components\":[{\"key\":\"a\"}]}'; }; sonar_list_projects"
  [ "$status" -ne 0 ]
}

@test "well-formed page lists keys" {
  run bash -c "source '$SCRIPT'; _sonar_get() { echo '{\"components\":[{\"key\":\"a\"}],\"paging\":{\"total\":1}}'; }; sonar_list_projects"
  [ "$status" -eq 0 ]
  [[ "$output" == *a* ]]
}
