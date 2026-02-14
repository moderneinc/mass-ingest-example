# AWS CLI for S3 URLs
# AWS CLI v2 requires glibc compatibility on Alpine
RUN apk add --no-cache groff less python3 py3-pip

# Install AWS CLI using pip (simpler on Alpine than the bundled installer)
RUN pip3 install --no-cache-dir awscli
