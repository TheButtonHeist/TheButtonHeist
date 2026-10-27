include "release-suites";

def require($condition; $message):
    if $condition then . else error($message) end;

require(type == "object"; "exact-SHA suite manifest must be an object")
| require(.schemaVersion == 1; "exact-SHA suite schemaVersion must be 1")
| require(.commit == $commit; "exact-SHA suite commit does not match requested commit")
| require(.workflow | type == "object"; "exact-SHA suite workflow must be an object")
| require(.workflow.ref == $workflowRef; "exact-SHA suite workflow ref does not match main CI")
| require(.workflow.sha == $commit; "exact-SHA suite workflow SHA does not match requested commit")
| require(.workflow.runId == $runId; "exact-SHA suite run ID does not match the downloaded run")
| require(.suites | type == "array"; "exact-SHA suites must be an array")
| require(
    all(.suites[]; type == "object" and (.name | type == "string"));
    "every exact-SHA suite must be a named object"
)
| require(
    ([.suites[].name] | sort) == required_release_suites;
    "exact-SHA suite names must contain every required suite exactly once"
)
| ([.suites[] | select(.conclusion != "success") | "\(.name)=\(.conclusion // "null")"]) as $failed
| require(
    ($failed | length) == 0;
    "required exact-SHA suites are not successful: \($failed | join(", "))"
)
