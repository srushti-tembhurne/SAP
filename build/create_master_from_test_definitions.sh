#!/bin/bash

CONFIG_FILE=$1
CURRENT_BUILD_NAME=$2
MASTER_TEST_SCRIPT=$3
SERVICE=$4

jqpath="./bin/tools/jq-linux-x86_64"

function generate_command {
    index_of_test=$1

    current_test=$($jqpath --arg config_index $index_of_test '.[$config_index|tonumber]' $CONFIG_FILE)
    cmd=$(echo $current_test | $jqpath -r '.script')

    # go thru each parameter and add to the command
    # logic is this: 
    #   if param name exists, 
    #     append it (separated by space)
    #     if param val exists
    #       append it (separated by space
    #   else
    #     append "default_arg"
    number_of_parameters=$(echo $current_test | $jqpath '.parameters|length')
    for ((i=0;i<$number_of_parameters;i++)); do
        current_parameter=$(echo $current_test | $jqpath --arg p_index $i '.parameters[$p_index|tonumber]')

        parameter_name=$(echo $current_parameter | $jqpath -r '.parameter_name')
        if [ ! -z $parameter_name ]; then
            cmd="$cmd $parameter_name"
            parameter_value=$(echo $current_parameter | $jqpath  -r '.parameter_value')
            if [ ! -z $parameter_value ]; then
                cmd="$cmd $parameter_value"
            fi
        else
            default_arg=$(echo $current_parameter | $jqpath -r '.default_arg')
            cmd=$(echo "$cmd $default_arg")
        fi
    done

    echo $cmd
}

function generate_test_block {
    test_number=$1
    cmd_to_run=$2
    validate_on=$3
    expected_output=$4
    secondary_command=$5

    cat << BEGIN_MY_BLOCK >> $MASTER_TEST_SCRIPT 

###############
# test ${test_number}
###############
echo ""
echo "Running Test #${test_number}:" '$cmd_to_run'
output=\$(eval $cmd_to_run)
cmd_exit_code=\$?
encoded_output=\$(echo -e "\$output" | base64)
expected_output="${expected_output}"

BEGIN_MY_BLOCK

    if [ "$validate_on" = "exit_code" ]; then
        cat << END_EXIT_CODE_BLOCK >> $MASTER_TEST_SCRIPT 
if [ \$cmd_exit_code -ne 0 ]; then
    echo "FAIL"
    echo "Output of failed exit code: \$output"
    exit_status=1
else
    echo "PASS"
fi
END_EXIT_CODE_BLOCK

    elif [ "$validate_on" = "secondary_command_exit_code" ]; then
        cat << END_SECONDARY_CMD_BLOCK >> $MASTER_TEST_SCRIPT 
secondary_cmd_output=\$(eval $secondary_command)
secondary_cmd_exit_code=\$?
if [ \$secondary_cmd_exit_code -ne 0 ]; then
    echo "FAIL"
    echo "Output of failed secondary command ($secondary_command): \$secondary_cmd_output"
    exit_status=1
else
    echo "PASS"
fi
END_SECONDARY_CMD_BLOCK

    else
        # default to validate_on=expected_value
        cat << END_EXPECTED_OUTPUT_BLOCK >> $MASTER_TEST_SCRIPT 
if [ -z "\$expected_output" ]; then
    # no, expected val provided, simply check the exit code
    if [ \$cmd_exit_code -ne 0 ]; then
        echo "FAIL"
        echo "Output of failed exit code: \$output"
        exit_status=1
    else
        echo "PASS"
    fi
elif [ "\$encoded_output" = "\$expected_output" ]; then
    echo "PASS"
else
    echo "FAIL"
    echo "Expected:" \$(echo -e \$expected_output | base64 -di)
    echo "Got:" \$(echo -e \$encoded_output | base64 -di)

    exit_status=1
fi
END_EXPECTED_OUTPUT_BLOCK

    fi
}

function master_test_script_header {
    num_of_tests=$1

    cat << MASTERHEADER > $MASTER_TEST_SCRIPT
#!/bin/bash

echo "Total Tests: ${num_of_tests}"

# 0 indicates success
exit_status=0

MASTERHEADER
}

function master_test_script_footer {
    cat << MASTERFOOTER >> $MASTER_TEST_SCRIPT

exit \$exit_status
MASTERFOOTER
    
    chmod +x $MASTER_TEST_SCRIPT
}

number_of_tests=$(cat $CONFIG_FILE | $jqpath '.|length')
master_test_script_header $number_of_tests

generate_test_block 0 "test -d /home/mon${SERVICE}/stratus/${CURRENT_BUILD_NAME}" "exit_code" "" ""
for testindex in $(seq 0 $((number_of_tests-1))); do

    cmd=$(generate_command $testindex) 
    validate_on=$($jqpath -r --arg config_index $testindex '.[$config_index|tonumber].validate_on' $CONFIG_FILE)
    expected_output=$($jqpath -r --arg config_index $testindex '.[$config_index|tonumber].expected_value' $CONFIG_FILE)
    secondary_command=$($jqpath -r --arg config_index $testindex '.[$config_index|tonumber].secondary_command' $CONFIG_FILE)

    generate_test_block $((testindex+1)) "$cmd" "$validate_on" "$expected_output" "$secondary_command"
done

master_test_script_footer
