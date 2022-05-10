#!/usr/bin/env bash
set -x
set -e

PLANSHOME="${HOME}/testground/plans"

# exit codes determine the result of the CheckRun
# https://docs.github.com/en/actions/creating-actions/setting-exit-codes-for-actions
SUCCESS=0
FAILURE=1

# For github to collect the action output, use these strings:
# Note that if you echo these strings, they will not be visible in the action log.
OUTPUT_STATUS="::set-output name=status::"
OUTPUT_OUTCOME="::set-output name=outcome::"
OUTPUT_ID="::set-output name=testground_id::"

# Make sure the input files exist.
test -d "${INPUT_PLAN_DIRECTORY}" || exit "${FALURE}"
test -f "${INPUT_COMPOSITION_FILE}" || exit "${FAILURE}"

REAL_PLAN_DIR=$(realpath $INPUT_PLAN_DIRECTORY)
REAL_COMP_FILE=$(realpath $INPUT_COMPOSITION_FILE)

# link plan to testground home
mkdir -p "${PLANSHOME}"
ln -s "${REAL_PLAN_DIR}" "${PLANSHOME}"

# Run test and wait until finished.
# There is a --wait option, so it might work to use it like this
# testground --endpoint "$INPUT_BACKEND_ENDPOINT" run composition -f "$REAL_COMP_FILE" --wait
# However, --wait doesn't always work well particularly for long-running jobs
# so instead, do a long poll.
testground --endpoint "${INPUT_BACKEND_ENDPOINT}" run composition \
  -f "${REAL_COMP_FILE}"                            \
  --metadata-repo "${GITHUB_REPOSITORY}"            \
  --metadata-branch "${GITHUB_REF#refs/heads/}"     \
  --metadata-commit "${GITHUB_SHA}" | tee run.out
TGID=$(awk '/run is queued with ID/ {print $10}' <run.out)

# Make sure the we received a run ID
if [ -z "$TGID" ]
then
	echo "${OUTPUT_OUTCOME}failure/not_queued"
	exit "${FAILURE}"
fi

echo "${OUTPUT_ID}${TGID}"

echo "Got testground ID ${TGID}"
echo -n "Testground started: "; date
echo "Waiting for job to complete."

while [ "${status}" != "complete" -a "${status}" != "canceled" ]
do
	sleep 30
	status=$(testground --endpoint "${INPUT_BACKEND_ENDPOINT}" status -t "${TGID}" | awk '/Status/ {print $2}')
	echo "last polled status is ${status}"
	echo "${OUTPUT_STATUS}${status}"
done

echo -n "Testground ended: "; date

echo getting extended status
testground --endpoint "${INPUT_BACKEND_ENDPOINT}" status -t "${TGID}" --extended  | tee extendedstatus.out
# Get the extened status, which includes a "Result" section.
# Capture the line that occurs after "Result:"
extstatus=$(awk '/Result/ {getline; print $0}' <extendedstatus.out)

# First off, there are control characters in this output, and we need to remove that.
# https://github.com/testground/testground/issues/1214
extstatus=$(echo "${extstatus}" | tr -d "[:cntrl:]" |  sed 's/\[0m//g')

# test if we got a result at all. The result might be "null". A null result means most likely the
# job was canceled before it began for some reason.
if [ "${extstatus}" == "null" ]
then
	echo "${OUTPUT_OUTCOME}failure/canceled"
	exit "$FAILURE"
fi

# Now find the outcome of the test. The extended result is going to look something like this:
# {"journal":{"events":{},"pods_statuses":{}},"outcome":"success","outcomes":{"providers":{"ok":1,"total":1},"requestors":{"ok":1,"total":1}}}

outcome=$(echo "${extstatus}" | jq ".outcome")

echo "the extended status was ${extstatus}"
echo "The outcome of this test was ${outcome}"
echo "${OUTPUT_OUTCOME}${outcome}"

test "${outcome}" = "\"success\"" && exit "${SUCCESS}" || exit "${FAILURE}"
