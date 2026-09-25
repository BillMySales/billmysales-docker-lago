# PostgreSQL with pg_partman, which Lago uses to partition its enriched events
# table. Same recipe as Lago's own image (getlago/postgres-partman), which is
# pinned to PostgreSQL 15.0 on an end-of-life Alpine; this one follows the
# current PostgreSQL patch release of the major version.
ARG POSTGRES_VERSION=15
FROM postgres:${POSTGRES_VERSION}-alpine

# pg_partman release (Lago's image: v5.4.0; the latest patch of that minor).
ARG PARTMAN_VERSION=v5.4.3
ARG PARTMAN_SHA256=c52e3b8cf80d306468f48fbdb1905e4c2574bf8362240af57aebbbf9e18c6fe2

# with_llvm=no: no JIT bitcode (it needs the exact clang version PostgreSQL was
# built with).
RUN set -eux; \
    apk add --no-cache --virtual .build-deps curl gcc make musl-dev; \
    curl -fsSL -o /tmp/pg_partman.tar.gz \
        "https://github.com/pgpartman/pg_partman/archive/refs/tags/${PARTMAN_VERSION}.tar.gz"; \
    if [ -n "${PARTMAN_SHA256}" ]; then \
        echo "${PARTMAN_SHA256}  /tmp/pg_partman.tar.gz" | sha256sum -c -; \
    fi; \
    mkdir -p /usr/src/pg_partman; \
    tar -xzf /tmp/pg_partman.tar.gz -C /usr/src/pg_partman --strip-components 1; \
    make -C /usr/src/pg_partman with_llvm=no; \
    make -C /usr/src/pg_partman with_llvm=no install; \
    rm -rf /usr/src/pg_partman /tmp/pg_partman.tar.gz; \
    apk del --no-network .build-deps; \
    ls /usr/local/lib/postgresql/pg_partman_bgw.so
