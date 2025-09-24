#!/bin/sh -eu

cd "/project"
  composer install
  composer exec -- phpunit "tests"
  composer exec -- phpstan
cd -
