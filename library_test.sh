#!/bin/sh -eu

if test "$(php -r "echo PHP_VERSION_ID < 80200 ? 'true' : 'false';")" = "true" || test "$(uname -m)" = "s390x"; then
  docker-php-ext-install "pdo" "pdo_mysql"
fi

cd "/project"
  cd "ext"
    phpize
    ./configure
    make -j"$(nproc)"
    TEST_PHP_ARGS="--show-diff -q" make test
    make install
    docker-php-ext-enable "colopl_timeshifter"
  cd -
  composer install
  composer exec -- phpunit "tests"
  composer exec -- phpstan
cd -
