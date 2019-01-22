# Stratus
NextGen Monitoring

## Description
This repo is where:
- modified "Cookies" code is kept to spit out influx line protocol "metrics" for telegraf (running on all hosts) to consume and feed into InfluxDB (a time-series database)
- above scripts are added to `base/config/telegraf_inputs_by_product_role.json` (which is used to create custom telegraf input configs) for telegraf to exec
- jenkins code to build and run tests on the `test` service

## Builds
- https://jenkins.ariba.com/job/stratus_develop_build_push_deploy_test/ (every ~30 minutes creates a new Stratus.Dev-XXX build if new changes in develop branch)
- https://jenkins.ariba.com/job/stratus_master_build_push_deploy_test/ (every ~30 minutes creates a new Stratus.Master-XXX build if new in master branch)
- https://jenkins.ariba.com/job/stratus_push_deploy_test/ (to push an existing Stratus build to a devlab service)

## Relevant Wiki Pages (related to the repo)
- [Git and CI Development Workflow](https://wiki.ariba.com/x/66_qAg)
- [Migration of Application Metrics](https://wiki.ariba.com/x/s5KqAg)
- [Migration Status](https://wiki.ariba.com/x/B5WqAg)
- [Defining Jenkins Tests](https://wiki.ariba.com/x/Y8CqAg)
- [Adding Scripts For Telegraf Config Discovery](https://wiki.ariba.com/x/_AHDAg)

## tests
 - there is a beginnings of a test harness for configuration validation (wiki TODO)
 - if you have docker (you should) you can run these tests with ./runtests

## Contact Us
- Slack Channels:
    - [#ces-tools](https://sap-ariba.slack.com/messages/C942P3GRJ) - General tools team discussions
    - [#cloudops-stratus](https://sap-ariba.slack.com/messages/C975MGM1S) - More stratus-specific discussions
    - [#stratus-devops-sre](https://sap-ariba.slack.com/messages/C995P7HLH) - Inputs/UX discussion
