# Android support
RUN wget --no-check-certificate https://dl.google.com/android/repository/commandlinetools-linux-8512546_latest.zip
RUN unzip commandlinetools-linux-8512546_latest.zip
RUN mkdir -p /usr/lib/android-sdk/cmdline-tools/latest/
RUN cp -R cmdline-tools/* /usr/lib/android-sdk/cmdline-tools/latest/
RUN yes | /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager --licenses
RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-33"
RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-32"
RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-31"
RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-30"
RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-29"
RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-28"
RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-27"
RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-26"
RUN /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "platforms;android-25"
ENV ANDROID_HOME=/usr/lib/android-sdk/cmdline-tools/latest
ENV ANDROID_SDK_ROOT=${ANDROID_HOME}
