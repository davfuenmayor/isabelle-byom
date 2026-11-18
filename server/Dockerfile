FROM makarius/isabelle:Isabelle2026@sha256:d6e7b8995f30a7e33172b750a1db9f5d46d39d8dcd59303c2390df4fdd5dae93
USER root
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates tini procps \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fL https://github.com/vi/websocat/releases/download/v1.14.2/websocat.x86_64-unknown-linux-musl -o /usr/local/bin/websocat \
    && echo 'cd26f92cb507f620e2d54fe6e126f4dc191f3eee90f2b53bccf07eac0645ec84  /usr/local/bin/websocat' | sha256sum -c - \
    && chmod 755 /usr/local/bin/websocat
COPY server/component /opt/byom/component
RUN export USER_HOME=/tmp/byom-build \
    && user_dir=$(/home/isabelle/Isabelle/bin/isabelle getenv -b ISABELLE_HOME_USER) \
    && mkdir -p "$user_dir/etc" \
    && echo 'init_component /opt/byom/component' > "$user_dir/etc/settings" \
    && /home/isabelle/Isabelle/bin/isabelle scala_build \
    && rm -rf /tmp/byom-build
COPY --chmod=755 server/start.sh server/credentials.sh /opt/byom/
USER isabelle
EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "-s", "--", "/opt/byom/start.sh"]
