#!/bin/bash

echo "==== STARTING ==== $0"

set -e

currentDir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

expectedNodeVersion="8"
expectedNpmVersion="5"

trap failure ERR

function failure {
    echo "=========================="
    echo "ERROR: An error occurred, script exiting."
    echo "=========================="
}

doInfo=false
if [[ $1 == --info ]]; then
    doInfo=true
else
    if [[ -z "$1" ]] || [[ $1 =~ --* ]]; then

        echo "Usage: $0 <branch> [--pull] [--install] [<other options>]" #  [--create]"
        echo "  The script checks whether the wicked repositories exist parallel to this repository (../..),"
        echo "  and checks out the given branch. It will only do that if there are no open changes, and/or there"
        echo "  are no unpushed or uncommitted changes."
        echo ""
        echo "Options:"
        echo "  --info    Just print branch information and quit."
        echo "  --pull    Also pull the latest changes from the origin."
        echo "  --install Install wicked SDK, portal-env and node_modules into the repositories"
        echo "  --fallback <branch>"
        echo "            Specify a fallback branch, in case the main branch is not present for a repository"
        exit 1
    fi
fi

branch=$1
doPull=false
doCreate=false
doInstall=false
ignoreVersions=false
manualFallbackBranch=""
if [[ ${doInfo} == false ]]; then
    shift 1
    while [[ ! -z "$1" ]]; do
        case "$1" in
            "--info")
                echo "ERROR: If you supply a branch, --info is not supported."
                exit 1
                ;;
            "--pull")
                doPull=true
                echo "INFO: Will try pull all repositories."
                ;;
            # "--create")
            #     echo "INFO: Will create branch in all repositories if not already present."
            #     doCreate=true
            #     ;;
            "--install")
                doInstall=true
                echo "INFO: Will run an npm install on JavaScript repos afterwards"
                ;;
            "--ignore-versions")
                ignoreVersions=true
                echo "INFO: Will ignore node/npm version mismatches."
                ;;
            "--fallback")
                shift 1
                manualFallbackBranch="$1"
                echo "INFO: Using manual fallback branch ${manualFallbackBranch}"
                ;;
            *)
                echo "ERROR: Unknown option: $1"
                exit 1
                ;;
        esac
        shift 1
    done

    # Sanity check node and npm
    nodeVersion=$(node -v)
    npmVersion=$(npm -v)
    if [[ ${nodeVersion} =~ ^v${expectedNodeVersion}\.* ]]; then
        echo "INFO: Detected node ${nodeVersion}, this is fine."
    else
        if [[ ${ignoreVersions} == false ]]; then
            echo "ERROR: wicked assumes node 8, you are running ${nodeVersion}."
            echo "To ignore this, use the --ignore-versions option."
            exit 1
        else
            echo "WARNING: wicked assumes node 8, you are running ${nodeVersion}, ignoring due to --ignore-versions."
        fi
    fi
    if [[ ${npmVersion} =~ ^${expectedNpmVersion}\.* ]]; then
        echo "INFO: Detected npm v${npmVersion}, this is fine."
    else
        if [[ ${ignoreVersions} == false ]]; then
            echo "ERROR: wicked assumes npm 5, you are running npm ${npmVersion}."
            echo "To ignore this, use the --ignore-versions option."
            exit 1
        else
            echo "WARNING: wicked assumes npm 5, you are running npm ${npmVersion}, ignoring due to --ignore-versions."
        fi
    fi
fi

baseUrl="https://github.com/apim-haufe-io/"

pushd ${currentDir} > /dev/null
. ../release/_repos.sh
pushd ../../ > /dev/null

function cloneRepo {
    echo "=====================" >> ./wicked.portal-tools/development/git-clone.log
    echo "Cloning repo $1" >> ./wicked.portal-tools/development/git-clone.log
    echo "=====================" >> ./wicked.portal-tools/development/git-clone.log
    git clone "${baseUrl}$1" >> ./wicked.portal-tools/git-clone.log
}

function hasBranch {
    local testBranch; testBranch=$1
    if [ -z "$(git branch -r | sed 's/^..//' | grep origin/${testBranch})" ]; then
        return 1
    fi
    return 0
}

function resolveBranch {
    local testBranch; testBranch=$1
    local fallback1; fallback1=${manualFallbackBranch}
    local fallback2; fallback2=next
    local fallback3; fallback3=master
    if hasBranch ${testBranch}; then
        echo ${testBranch}
        return 0
    elif [[ -n "${fallback1}" ]] && hasBranch ${fallback1}; then
        echo ${fallback1}
        return 0
    elif hasBranch ${fallback2}; then
        echo ${fallback2}
        return 0
    elif hasBranch ${fallback3}; then
        echo ${fallback3}
        return 0
    fi
    return 1
}

function checkoutBranch {
    thisRepo=$1
    inputBranchName=$2
    pushd ${thisRepo} > /dev/null

    local branchName gitStatus gitCherry currentBranch

    git fetch

    # Check if branch is present
    branchName=$(resolveBranch ${inputBranchName})
    if [[ ${branchName} != ${inputBranchName} ]]; then
        echo "WARNING: Repository ${repo} doesn't have branch ${inputBranchName}, falling back to ${branchName}."
    fi
    currentBranch=$(git rev-parse --abbrev-ref HEAD)
    if [[ "${currentBranch}" == "${branchName}" ]]; then
        echo "INFO: Current branch in repository ${repo} already is ${branchName}."
    else
        echo "INFO: Attempting to switch branch to ${branchName} in repository ${repo}"
        gitStatus="$(git status -s)"
        if [ ! -z "${gitStatus}" ]; then
            echo "ERROR: Repository ${thisRepo} has an unclean status:"
            echo "${gitStatus}"
            return 1
        fi
        gitCherry="$(git cherry -v)"
        if [ ! -z "${gitCherry}" ]; then
            echo "ERROR: Repository ${thisRepo} has unpushed commits:"
            echo "${gitCherry}"
            return 1
        fi
        git checkout ${branchName}
        echo "INFO: Success, ${thisRepo} is now at branch ${branchName}"
    fi

    [[ ${doPull} == true ]] && git pull

    popd > /dev/null
    return 0
}

function printBranchInfo {
    local thisRepo currentBranch isDirty needsPush
    thisRepo=$1
    if [ ! -d $thisRepo ]; then
        echo "WARNING: Could not find repository ${thisRepo}, has it been cloned?"
    else
        pushd ${thisRepo} > /dev/null
        currentBranch=$(git rev-parse --abbrev-ref HEAD)
        isDirty=""
        needsPush=""
        if [ -n "$(git status -s)" ]; then isDirty=Yes; fi
        if [ -n "$(git cherry -v)" ]; then needsPush=Yes; fi
        printf "%-30s %-20s %-8s %-10s\n" "${thisRepo}" "${currentBranch}" "${isDirty}" "${needsPush}"
        popd > /dev/null
    fi
}

function runNpmInstall {
    thisRepo=$1
    pushd ${thisRepo} > /dev/null
    echo "INFO: Running npm install for repository ${thisRepo}"
    npm install > /dev/null
    popd > /dev/null
}

if [[ ${doInfo} == false ]]; then
    for repo in ${sourceRepos}; do
        if [ ! -d ${repo} ]; then
            # Repo doesn't exist already
            cloneRepo ${repo}
        fi
        checkoutBranch ${repo} ${branch}
    done
else
    echo ""
    printf "%-30s %-20s %-8s %-10s\n" "Repository" "Branch" "Dirty" "Needs push"
    echo "------------------------------------------------------------------------"
    for repo in ${sourceRepos}; do
        printBranchInfo ${repo}
    done
    echo "------------------------------------------------------------------------"
    echo ""
fi

if [[ ${doInstall} == true ]]; then
    runNpmInstall wicked.portal-env
    # Add the wicked.node-sdk to where it needs to be
    ./wicked.node-sdk/install-local-sdk.sh
    # Add the portal-env package
    ./wicked.portal-env/local-update-portal-env.sh
    for repo in ${versionDirs}; do
        if [[ ${repo} != wicked.portal-env ]]; then
            runNpmInstall ${repo}
        fi
    done
fi

popd > /dev/null # ../..
popd > /dev/null # ${currentDir}

echo "=========================="
echo "SUCCESS: $0"
echo "=========================="