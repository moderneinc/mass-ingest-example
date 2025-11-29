# Bazel support
RUN wget --no-check-certificate https://github.com/bazelbuild/bazelisk/releases/download/v1.20.0/bazelisk-linux-amd64
RUN cp bazelisk-linux-amd64 /usr/local/bin/bazel
RUN chmod +x /usr/local/bin/bazel
