# Python support
RUN apk add --no-cache python3 py3-pip python3-dev

# Install required Python packages
RUN pip3 install --no-cache-dir more-itertools cbor2
