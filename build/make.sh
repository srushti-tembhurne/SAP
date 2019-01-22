#!/bin/bash

PROXYHOST="tproxy.aws.ariba.com"
PROXYPORT="22"
HTTPPROXYHOST="10.163.3.125"
HTTPPROXYPORT="443"
#export http_proxy="http://proxy02.ariba.com:8080"
#export https_proxy="http://proxy02.ariba.com:8080"
export http_proxy="$HTTPPROXYHOST:$HTTPPROXYPORT"
export https_proxy="$HTTPPROXYHOST:$HTTPPROXYPORT"
export SSHPASS="${REMOTE_CI_USER_PW}"

action=$1
subaction=$2

ARTIFACT_NAME="stratus.tar.gz"
LOCAL_TEST_DIR="./tests"
MASTER_TEST_SCRIPT_BASENAME="master_tests.sh"

CURRENT_BUILD_NAME_FILE="${LOCAL_TEST_DIR}/current_build_name"
DEFINITIONS_OF_TESTS_FILE="${LOCAL_TEST_DIR}/definitions.json"
MASTER_TEST_SCRIPT="${LOCAL_TEST_DIR}/${MASTER_TEST_SCRIPT_BASENAME}"

SERVICE=${REMOTE_CI_USER:3}

##########
# Let's create a new Stratus-XXX build.
# Call the penguin jenkins job and record the 
#   buildname and status
##########
if [ "$action" = "build-deploy" ]; then

    #JOB_URL="https://jenkins.ariba.com/job/stratus_develop"
    #REPUSH_JOB_URL="https://jenkins.ariba.com/job/stratus-repush"
    JOB_URL="https://10.163.2.171/job/stratus_develop_build_push_deploy_test"
    REPUSH_JOB_URL="https://10.163.2.171/job/stratus_push_deploy_test"
    TOKEN="5tratu5"

    # trigger the build
    if [ "$subaction" = "push-only" ]; then
        curl -k -X POST ${REPUSH_JOB_URL}/buildWithParameters\?token\=${TOKEN}\&MON_MASTER_PW\=${MASTER_PW}\&BUILD_NAME\=${STRATUS_BUILD}\&SERVICE\=${SERVICE}\&MONSERVER\=${REMOTE_CI_SERVER}
    else
        curl -k -X POST ${JOB_URL}/buildWithParameters\?token\=${TOKEN}\&MON_MASTER_PW\=${MASTER_PW}\&SERVICE\=${SERVICE}\&MONSERVER\=${REMOTE_CI_SERVER}
    fi

    if [ "$subaction" = "push-only" ]; then
        JOB_URL=${REPUSH_JOB_URL}
    fi

    job_status=$(curl -s ${JOB_URL}/lastBuild/api/json  | jq -r '.result')
    while [ "$job_status" != "null" ]; do
        echo "Waiting for job to start..."
        sleep 1
        job_status=$(curl -k -s ${JOB_URL}/lastBuild/api/json  | jq -r '.result')
    done

    echo "Job started... waiting for result..."
    while [ "$job_status" = "null" ]; do
        sleep 3
        job_status=$(curl -k -s ${JOB_URL}/lastBuild/api/json  | jq -r '.result')
    done

    display_name=$(curl -k -s ${JOB_URL}/lastBuild/api/json  | jq -r '.displayName')
    build_url=$(curl -k -s ${JOB_URL}/lastBuild/api/json  | jq -r '.url')
    if [ "$subaction" = "push-only" ]; then
        display_name=${STRATUS_BUILD}
    fi

    echo $display_name > $CURRENT_BUILD_NAME_FILE
    echo "Stratus Maven Build Name: ${display_name}"
    echo "Stratus Maven Build URL: ${build_url}"
    
    # check status again after a while to make sure indeed post-build scripts ran fine too
    # a successful push takes ~40s
    sleep 40
    job_status=$(curl -k -s ${JOB_URL}/lastBuild/api/json  | jq -r '.result')
    if [ "$job_status" = "SUCCESS" ]; then
        echo "Succeeded!!"
        exit 0
    else
        echo "Failed!"
        exit 1
    fi
fi

##########
# At this point, build should be on the CI server
# Let's move it to the stratus/ folder and run control-deployment
#
# NOTE: THIS IS DEPRECATED! 'build-deploy' option handles all this 
##########
if [ "$action" = "deploy" ]; then

    BUILD_NAME=$(cat $CURRENT_BUILD_NAME_FILE)

    cat > ./build/deploy.sh << EOF
#!/bin/bash
cd /home/mon${SERVICE}/stratus;

attempt=0;
max_attempts=20;
while [ ! -d "${BUILD_NAME}" ]; do
    if [ "\$attempt" -gt "\$max_attempts" ]; then
        echo "Cannot find the build. Exiting 1";
        exit 1;
    fi

    echo "waiting for ${BUILD_NAME}...";
    sleep 3;

    attempt=\$((attempt + 1));
done

echo "Found build ${BUILD_NAME}... deploying";
cd /home/${REMOTE_CI_USER}/stratus/${BUILD_NAME}
sync
sleep 3
sync
pwd && ls -l bin/control-deployment
./bin/control-deployment -cluster primary stratus ${SERVICE} install -buildname ${BUILD_NAME}

EOF

    chmod +x ./build/deploy.sh
    sshpass -e scp -o StrictHostKeyChecking=no ./build/deploy.sh ${REMOTE_CI_USER}@${REMOTE_CI_SERVER}:/tmp/stratus_deploy.sh
    sshpass -e ssh -o StrictHostKeyChecking=no -l $REMOTE_CI_USER $REMOTE_CI_SERVER "printf ${MASTER_PW}\n | /bin/bash /tmp/stratus_deploy.sh"
    sshpass -e ssh -o StrictHostKeyChecking=no -l $REMOTE_CI_USER $REMOTE_CI_SERVER "printf ${MASTER_PW}\n | /home/${REMOTE_CI_USER}/stratus/bin/stratus-discovery -dc lab1 -deploy"

fi

##########
# Create the master test script, copy it over and run it 
##########
if [ "$action" = "test" ]; then

    # create the master test script (to be run on test server)
    ./build/create_master_from_test_definitions.sh $DEFINITIONS_OF_TESTS_FILE $(cat $CURRENT_BUILD_NAME_FILE) $MASTER_TEST_SCRIPT $SERVICE

    # copy tests to destination server ("build" step along with make-push already pushed the build there
    sshpass -e scp -o StrictHostKeyChecking=no ${MASTER_TEST_SCRIPT} ${REMOTE_CI_USER}@${REMOTE_CI_SERVER}:/tmp/${MASTER_TEST_SCRIPT_BASENAME}

    # execute the tests (as root in future), allow arbitrary delay for sync
    sshpass -e ssh -o StrictHostKeyChecking=no -l $REMOTE_CI_USER $REMOTE_CI_SERVER /bin/bash /tmp/${MASTER_TEST_SCRIPT_BASENAME}
fi
