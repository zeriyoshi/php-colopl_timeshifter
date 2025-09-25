#!/bin/sh -eu

if test "$(php -m | grep -c "pdo_mysql")" -eq 0; then
  docker-php-ext-install "pdo" "pdo_mysql"
fi

cd "/project"
  cd "ext"
    phpize
    ./configure
    make -j"$(nproc)"
    TEST_PHP_ARGS="--show-diff -q -d extension=$(php-config --extension-dir)/pdo_mysql.so" make test
    make install
    docker-php-ext-enable "colopl_timeshifter"
  cd -
  composer install
  composer exec -- phpunit "tests"
  composer exec -- phpstan
cd -
