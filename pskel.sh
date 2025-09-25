#!/bin/sh

set -e

get_ext_dir() {
  PSKEL_EXT_DIR="/ext"

  if test -d "${CODESPACE_VSCODE_FOLDER}"; then
    echo "[Pskel] GitHub Codespace workspace detected, using \"${CODESPACE_VSCODE_FOLDER}/ext\"." >&2
    PSKEL_EXT_DIR="${CODESPACE_VSCODE_FOLDER}/ext"
  elif test -d "/workspaces/pskel/ext"; then
    echo "[Pskel] Development Containers workspace detected, using \"/workspaces/pskel/ext\"." >&2
    PSKEL_EXT_DIR="/workspaces/pskel/ext"
  elif test -f "/ext/.gitkeep" && test "$(cat "/ext/.gitkeep")" = "pskel_uninitialized" && test "${1}" != "--no-init"; then
    echo "[Pskel] Uninitialized project detected, initializing default skeleton." >&2
    cmd_init "skeleton" >&2
  fi

  echo "${PSKEL_EXT_DIR}"
}

cmd_usage() {
    cat << EOF
Usage: ${0} [task] ...

Available commands:
    init        create new extension
    test        test extension
    build       build PHP runtime
    coverage    generate code coverage
EOF
}

cmd_init() {
  case "${1}" in
    -h|--help)
      cat << EOF
Usage: ${0} init [extension_name] [ext_skel.php options...]
EOF
      return 0
      ;;
    "")
      echo "Error: Extension name is required." >&2
      return 1
      ;;
  esac

  PSKEL_EXT_DIR="$(get_ext_dir --no-init)"
  /usr/local/bin/php "/usr/src/php/ext/ext_skel.php" --ext "${1}" --dir "/tmp" "${@}"
  rm "${PSKEL_EXT_DIR}/.gitkeep"
  rsync -av "/tmp/${1}/" "${PSKEL_EXT_DIR}/"
  rm -rf "/tmp/${1}"
}

cmd_test() {
  case "${1}" in
    -h|--help)
      cat << EOF
Usage: ${0} test [test_type|php_binary_name]
Environment variables:
  CFLAGS, CPPFLAGS:     Compilation flags
  TEST_PHP_ARGS:        Test flags
EOF
      return 0
      ;;
    debug|gcov|valgrind)
      CC="$(command -v "gcc")"
      CXX="$(command -v "g++")"
      case "${1}" in
        debug) CONFIGURE_OPTS="${CONFIGURE_OPTS} --enable-debug" build_php_if_not_exists "debug";;
        gcov)
          CFLAGS="${CFLAGS} --coverage" CONFIGURE_OPTS="${CONFIGURE_OPTS} --enable-debug --enable-gcov" build_php_if_not_exists "gcov"
          ;;
        valgrind)
          CONFIGURE_OPTS="${CONFIGURE_OPTS} --enable-debug --with-valgrind" build_php_if_not_exists "valgrind"
          TEST_PHP_ARGS="${TEST_PHP_ARGS} -m"
          ;;
      esac
      CMD="$(basename "${CC}")-${1}-php"
      ;;
    msan|asan|ubsan)
      CC="$(command -v "clang")"
      CXX="$(command -v "clang++")"
      case "${1}" in
        msan)
          CFLAGS="${CFLAGS} -fsanitize=memory"
          LDFLAGS="${LDFLAGS} -fsanitize=memory"
          CONFIGURE_OPTS="${CONFIGURE_OPTS} --enable-debug --enable-memory-sanitizer"
          build_php_if_not_exists "msan"
          ;;
        asan)
          CFLAGS="${CFLAGS} -fsanitize=address"
          LDFLAGS="${LDFLAGS} -fsanitize=address"
          CONFIGURE_OPTS="${CONFIGURE_OPTS} --enable-debug --enable-address-sanitizer"
          build_php_if_not_exists "asan"
          ;;
        ubsan)
          CFLAGS="${CFLAGS} -fsanitize=undefined"
          LDFLAGS="${LDFLAGS} -fsanitize=undefined"
          CONFIGURE_OPTS="${CONFIGURE_OPTS} --enable-debug --enable-undefined-sanitizer"
          build_php_if_not_exists "ubsan"
          ;;
      esac
      CMD="$(basename "${CC}")-${1}-php"
      ;;
    "")
      CMD="php"
      ;;
    *)
      build_php_if_not_exists "${1}"
      CMD="${1}-php"
      ;;
  esac

  for BIN in "${CMD}" "${CMD}ize" "${CMD}-config"; do
    if ! command -v "${BIN}" >/dev/null 2>&1; then
      if ! check_and_restore_cached_php "${1}" "${1}" "${CC}" "${CONFIGURE_OPTS}"; then
        echo "Error: Invalid argument '${CMD}', executable file not found" >&2
        exit 1
      fi
    fi
  done

  PSKEL_EXT_DIR="$(get_ext_dir)"

  cd "${PSKEL_EXT_DIR}"
    "${CMD}ize"
    if test "$("${CMD}" -r "echo PHP_VERSION_ID;")" -lt "80400"; then
      patch "./build/ltmain.sh" "./../patches/ltmain.sh.patch"
      echo "[Pskel] ltmain.sh patched" >&2
    fi
    CC="${CC}" CXX="${CXX}" CFLAGS="${CFLAGS}" CPPFLAGS="${CPPFLAGS}" LDFLAGS="${LDFLAGS}" ./configure --with-php-config="$(command -v "${CMD}-config")"
    make clean
    make -j"$(nproc)"
    "${CMD}" "run-tests.php" ${TEST_PHP_ARGS} --show-diff -q
  cd -
}

build_php_if_not_exists() {
  PREFIX="${1}"
  if test -n "${CC}"; then
    PREFIX="$(basename "${CC}")-${PREFIX}"
  fi

  if test -d "${PHP_CACHE_DIR}"; then
    if check_and_restore_cached_php "${PREFIX}" "${1}" "${CC}" "${CONFIGURE_OPTS}"; then
      return 0
    fi
  fi

  if ! command -v "${PREFIX}-php" >/dev/null 2>&1; then
    CC="${CC}" \
    CXX="${CXX}" \
    CFLAGS="${CFLAGS} -DZEND_TRACK_ARENA_ALLOC" \
    CPPFLAGS="${CFLAGS}" \
    LDFLAGS="${LDFLAGS}" \
    CONFIGURE_OPTS="${CONFIGURE_OPTS} $(php -r "echo PHP_ZTS === 1 ? '--enable-zts' : '';") --enable-option-checking=fatal --disable-phpdbg --disable-cgi --disable-fpm --enable-cli --without-pcre-jit --disable-opcache-jit --disable-zend-max-execution-timers" \
      cmd_build "${PREFIX}" "${1}"
  fi
}

check_and_restore_cached_php() {
  PREFIX="${1}"
  BUILD_TYPE="${2}"
  COMPILER="$(basename "${3}")"
  CONFIGURE_OPTS_LOCAL="${4}"

  CACHE_KEY="$(generate_cache_key "${BUILD_TYPE}" "${COMPILER}")"
  CACHE_DIR="${PHP_CACHE_DIR}/${CACHE_KEY}"

  if test -f "${CACHE_DIR}/.build_complete"; then
    for BIN in php phpize php-config; do
      if test -f "${CACHE_DIR}/bin/${PREFIX}-${BIN}"; then
        ln -sf "${CACHE_DIR}/bin/${PREFIX}-${BIN}" "/usr/local/bin/${PREFIX}-${BIN}"
      fi
    done

    if test -d "${CACHE_DIR}/include/${PREFIX}-php"; then
      ln -sf "${CACHE_DIR}/include/${PREFIX}-php" "/usr/local/include/${PREFIX}-php"
    fi

    echo "[Pskel > Cache] Restored PHP header and binary: ${PREFIX}-php" >&2

    return 0
  fi

  return 1
}

generate_cache_key() {
  BUILD_TYPE="${1}"
  COMPILER="$(basename "${2}")"
  PHP_VERSION="$(php -r 'echo PHP_VERSION;')"

  if test -n "${CONTAINER_IMAGE_HASH}"; then
    IMAGE_HASH="${CONTAINER_IMAGE_HASH}"
  else
    IMAGE_HASH=""
    if test -d "/usr/src/php"; then
      docker-php-source delete
      docker-php-source extract
      IMAGE_HASH="$(cd /usr/src/php && find . -type f \( -name "*.c" -o -name "*.h" \) -exec sha256sum {} \; | sha256sum | cut -d' ' -f1 | cut -c1-16)"
    fi
  fi

  echo "php-${PHP_VERSION}-${BUILD_TYPE}-${COMPILER}-${IMAGE_HASH}"
}

cache_php_build() {
  PREFIX="${1}"
  BUILD_TYPE="${2}"
  COMPILER="$(basename "${3}")"
  ORIG_NAME="${4}"

  CACHE_KEY="$(generate_cache_key "${ORIG_NAME}" "${COMPILER}")"
  CACHE_DIR="${PHP_CACHE_DIR}/${CACHE_KEY}"

  mkdir -p "${CACHE_DIR}/bin"
  mkdir -p "${CACHE_DIR}/include"

  for BIN in php phpize php-config; do
    if test -f "/usr/local/bin/${PREFIX}-${BIN}"; then
      cp -a "/usr/local/bin/${PREFIX}-${BIN}" "${CACHE_DIR}/bin/${PREFIX}-${BIN}"
    fi
  done

  if test -d "/usr/local/include/${PREFIX}-php"; then
    cp -a "/usr/local/include/${PREFIX}-php" "${CACHE_DIR}/include/${PREFIX}-php"
  fi

  touch "${CACHE_DIR}/.build_complete"
  echo "[Pskel > Cache] Cached PHP header and binary: ${PREFIX}-php" >&2
}

cmd_build() {
  case "${1}" in
    -h|--help)
      cat << EOF
Usage: ${0} build [php_binary_prefix]
Environment variables:
  CFLAGS, CPPFLAGS:     Compilation flags
  CONFIGURE_OPTS:       ./configure options
EOF
      return 0
      ;;
    ?*)
      CONFIGURE_OPTS="--program-prefix=${1}- --includedir=/usr/local/include/${1}-php ${CONFIGURE_OPTS}"
      ;;
  esac

  cd "/usr/src/php"
    ./buildconf --force
    ./configure ${CONFIGURE_OPTS}
    make clean
    make -j"$(nproc)"
    make install
    make clean
  cd -

  if test -n "${2}"; then
    ORIG_NAME="${2}";
  else
    ORIG_NAME="${1}";
  fi

  if test -d "${PHP_CACHE_DIR}"; then
    cache_php_build "${1}" "${1}" "${CC}" "${ORIG_NAME}"
  fi
}

cmd_coverage() {
  case "${1}" in
    -h|--help)
      cat << EOF
Usage: ${0} coverage
Environment variables:
  LCOV_OPTS:    lcov capture options
EOF
      return 0
      ;;
  esac

  cmd_test "gcov"

  PSKEL_EXT_DIR="$(get_ext_dir)"

  lcov --capture --directory "${PSKEL_EXT_DIR}" ${LCOV_OPTS} --exclude "/usr/local/include/*" --output-file "${PSKEL_EXT_DIR}/lcov.info"
  lcov --list "${PSKEL_EXT_DIR}/lcov.info"
}

if test $# -eq 0; then
  cmd_usage
  exit 1
fi

case "${1}" in
  help) shift; cmd_usage;;
  init) shift; cmd_init "${@}";;
  test) shift; cmd_test "${@}";;
  build) shift; cmd_build "${@}";;
  coverage) shift; cmd_coverage "${@}";;
  *)
    echo "${0} error: invalid command: '${1}'" >&2
    cmd_usage
    exit 1
    ;;
esac
