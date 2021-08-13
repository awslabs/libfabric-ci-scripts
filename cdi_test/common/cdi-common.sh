#!/bin/bash

ami_arch="x86_64"
label="alinux"
SSH_USER="ec2-user"
NODES=2
PROVIDER="efa"
ENABLE_PLACEMENT_GROUP=1

create_cdi_test_user() {
    POLICY_ARN=$(aws iam create-policy --policy-name ${POLICY_NAME} \
                     --policy-document "file://${CDI_POLICY_DOCUMENT}" | jq -r '.Policy.Arn')
    aws iam create-group --group-name ${GROUP_NAME}
    aws iam create-user --user-name ${USER_NAME}
    aws iam add-user-to-group --group-name ${GROUP_NAME} --user-name ${USER_NAME}
    # Attach CloudWatchAgentServerPolicy
    cloudwatchagentserverpolicy=$(aws iam list-policies --query 'Policies[?PolicyName==`CloudWatchAgentServerPolicy`].{ARN:Arn}' --output text)
    aws iam attach-user-policy --user-name ${USER_NAME} --policy-arn ${cloudwatchagentserverpolicy}
    aws iam attach-user-policy --user-name ${USER_NAME} --policy-arn ${POLICY_ARN}
}

delete_cdi_test_user() {
    aws iam delete-access-key --access-key-id ${AWS_ACCESS_KEY_ID} --user-name ${USER_NAME}
    aws iam detach-user-policy --user-name ${USER_NAME} --policy-arn ${cloudwatchagentserverpolicy}
    aws iam detach-user-policy --user-name ${USER_NAME} --policy-arn ${POLICY_ARN}
    aws iam remove-user-from-group --group-name ${GROUP_NAME} --user-name ${USER_NAME}
    aws iam delete-policy --policy-arn ${POLICY_ARN}
    aws iam delete-user --user-name ${USER_NAME}
    aws iam delete-group --group-name ${GROUP_NAME}
}
