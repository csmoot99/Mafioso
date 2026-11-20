#!/usr/bin/env bash
# bin/fm-brief.sh --combine wrote this for one qwen combine; the worker runs it as
#   bash <this file> fold <n> | commit <n> | publish
STATUS=/home/work/.no-mistakes/worktrees/5f69104d19ce/01M7VKR3HV925EC3NA45YYP7Z0/.test-phase-tmp/live-home/state/qwen-combine.status
BRANCH=fm/qwen-combine
BASE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PR_BASE=''
MARK=/home/work/.no-mistakes/worktrees/5f69104d19ce/01M7VKR3HV925EC3NA45YYP7Z0/.test-phase-tmp/live-home/data/qwen-combine/combine-stopped
GATE=make\ combined-test
TITLE=Combine\ two\ reviewed\ changes
BODY=$'Combines these approved PRs, each folded at its exact head with a merge commit:\n\n- https://github.com/o/r/pull/11 at 1111111111111111111111111111111111111111\n- https://github.com/o/r/pull/12 at 2222222222222222222222222222222222222222\n'
HEADS=('' 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 )
MSGS=('' Merge\ #11\ from\ pr11\ at\ 1111111111111111111111111111111111111111 Merge\ #12\ from\ pr12\ at\ 2222222222222222222222222222222222222222 )
EXPECT=('' '' '' )
NOTES=('' '' '' )
. /home/work/.no-mistakes/worktrees/5f69104d19ce/01M7VKR3HV925EC3NA45YYP7Z0/bin/fm-qwen-combine.sh
