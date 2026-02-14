# Python support
# Install prerequisites and add the deadsnakes PPA
RUN apt-get update && apt-get install -y \
    software-properties-common \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update

# Install Python 3.11 and pip
RUN apt-get install -y \
    python3.11 \
    python3.11-venv \
    python3.11-dev \
    python3.11-distutils \
    && apt-get -y autoremove \
    && apt-get clean

# Set Python 3.11 as the default
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 && \
   update-alternatives --config python3

# Install pip for Python 3.11 using the bundled `ensurepip` and upgrade it
RUN python3.11 -m ensurepip --upgrade

# Update pip to the latest version for the installed Python 3.11
RUN python3.11 -m pip install --upgrade pip

RUN python3.11 -m pip install more-itertools cbor2
