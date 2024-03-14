#!/bin/sh

# Default Docker entrypoint script to start supervisord
/usr/bin/supervisord --loglevel=error --directory=/tmp --configuration=/etc/supervisord.conf