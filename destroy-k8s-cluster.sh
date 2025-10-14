#!/bin/bash

sudo kubeadm reset -f

sudo restart kubelet
