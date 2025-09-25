#!/bin/sh -eu

if test "$(php -m | grep -c "pdo_mysql")" -eq 0; then
  docker-php-ext-install "pdo" "pdo_mysql"
fi

cd "/project"
  cd "ext"
    phpize
    ./configure
    make -j"$(nproc)"
    make install
    docker-php-ext-enable "colopl_timeshifter"
    php "run-tests.php" --show-diff -q
  cd -
  composer install
  composer exec -- phpunit "tests"
  composer exec -- phpstan
cd -
