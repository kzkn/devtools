#!/bin/bash

# 上下に7:3で分割
tmux split-window -v -p 30

# 上のペイン（pane 0）を選択して左右6:4で分割
tmux select-pane -t 0
tmux split-window -h -p 40

# 左上にフォーカスを戻す
tmux select-pane -t 0
