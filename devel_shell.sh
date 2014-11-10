#!/bin/bash

DIR=`cd $(dirname $0); pwd`

erl -pz $DIR/deps/*/ebin -pa $DIR/ebin -s consensus_demo_app \
#    -eval 'application:start(consensus_demo).'
