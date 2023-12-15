FROM ubuntu:22.04

# If you are not running as root you might need to use "sudo apt" instead

# STEP 1 (with mods)

RUN apt update
# TODO wget is not part of base ubuntu image
RUN apt -y install git build-essential perl cmake autoconf libtool zlib1g-dev libexpat1-dev libpcre3 libpcre3-dev wget


RUN useradd -ms /bin/bash blog
USER blog
WORKDIR /home/blog

ENV WORKSPACE /home/blog/quantumsafe 
ENV BUILD_DIR $WORKSPACE/build
RUN mkdir -p $BUILD_DIR/lib64
RUN ln -s $BUILD_DIR/lib64 $BUILD_DIR/lib

# STEP 2

WORKDIR $WORKSPACE
RUN git clone https://github.com/openssl/openssl.git
WORKDIR openssl

#OPTIONAL# git checkout c8ca810da9

RUN ./Configure \
  --prefix=$BUILD_DIR \
  no-ssl no-tls1 no-tls1_1 no-afalgeng \
  no-shared threads -lm

RUN make -j $(nproc)
RUN make -j $(nproc) install_sw install_ssldirs


# STEP 3
WORKDIR $WORKSPACE

RUN git clone https://github.com/open-quantum-safe/liboqs.git
WORKDIR $WORKSPACE/liboqs

#OPTIONAL# git checkout 78e65bf1

RUN mkdir build
WORKDIR $WORKSPACE/liboqs/build

RUN cmake \
  -DCMAKE_INSTALL_PREFIX=$BUILD_DIR \
  -DBUILD_SHARED_LIBS=ON \
  -DOQS_USE_OPENSSL=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DOQS_BUILD_ONLY_LIB=ON \
  -DOQS_DIST_BUILD=ON \
  ..

RUN make -j $(nproc)
RUN make -j $(nproc) install

# STEP 4

WORKDIR $WORKSPACE

RUN git clone https://github.com/open-quantum-safe/oqs-provider.git
WORKDIR oqs-provider

#OPTIONAL# git checkout d540c28
ENV liboqs_DIR $BUILD_DIR 
RUN cmake \
  -DCMAKE_INSTALL_PREFIX=$WORKSPACE/oqs-provider \
  -DOPENSSL_ROOT_DIR=$BUILD_DIR \
  -DCMAKE_BUILD_TYPE=Release \
  -S . \
  -B _build
RUN cmake --build _build

# Manually copy the lib files into the build dir
RUN cp _build/lib/* $BUILD_DIR/lib/

# We need to edit the openssl config to use the oqsprovider
RUN sed -i "s/default = default_sect/default = default_sect\noqsprovider = oqsprovider_sect/g" $BUILD_DIR/ssl/openssl.cnf 
RUN sed -i "s/\[default_sect\]/\[default_sect\]\nactivate = 1\n\[oqsprovider_sect\]\nactivate = 1\n/g" $BUILD_DIR/ssl/openssl.cnf

# These env vars need to be set for the oqsprovider to be used when using OpenSSL
ENV OPENSSL_CONF $BUILD_DIR/ssl/openssl.cnf
ENV OPENSSL_MODULES $BUILD_DIR/lib
RUN $BUILD_DIR/bin/openssl list -providers -verbose -provider oqsprovider

# STEP 5

WORKDIR  $WORKSPACE

RUN git clone https://github.com/curl/curl.git
WORKDIR curl

#OPTIONAL# git checkout 0eda1f6c9

RUN autoreconf -fi
RUN ./configure \
  LIBS="-lssl -lcrypto -lz" \
  LDFLAGS="-Wl,-rpath,$BUILD_DIR/lib64 -L$BUILD_DIR/lib64 -Wl,-rpath,$BUILD_DIR/lib -L$BUILD_DIR/lib -Wl,-rpath,/lib64 -L/lib64 -Wl,-rpath,/lib -L/lib" \
  CFLAGS="-O3 -fPIC" \
  --prefix=$BUILD_DIR \
  --with-ssl=$BUILD_DIR \
  --with-zlib=/ \
  --enable-optimize --enable-libcurl-option --enable-libgcc --enable-shared \
  --enable-ldap=no --enable-ipv6 --enable-versioned-symbols \
  --disable-manual \
  --without-default-ssl-backend \
  --without-librtmp --without-libidn2 \
  --without-gnutls --without-mbedtls \
  --without-wolfssl --without-libpsl

RUN make -j $(nproc)
RUN make -j $(nproc) install

# TEST connection
RUN $BUILD_DIR/bin/curl -vk https://test.openquantumsafe.org/CA.crt --output $BUILD_DIR/ca.cert

RUN $BUILD_DIR/bin/curl -v --curves p521_kyber1024 --cacert $BUILD_DIR/ca.cert https://test.openquantumsafe.org:6130/

# ----
# This is where we might split for a second image. But for portability right now, will continue. refactor later!
# ----

ENV OPENSSL_PATH $BUILD_DIR
# These test commands aren't really that useful here

# STEP 1 
RUN $OPENSSL_PATH/bin/openssl list -providers -verbose -provider oqsprovider
WORKDIR $WORKSPACE
RUN $OPENSSL_PATH/bin/openssl req -x509 -new -newkey dilithium5 -keyout CA.key -out CA.crt -nodes -subj "/CN=oqstest CA" -days 365 -config $OPENSSL_PATH/ssl/openssl.cnf
RUN $OPENSSL_PATH/bin/openssl req -new -newkey dilithium5 -keyout server.key -out server.csr -nodes -subj "/CN=c13762v1.fyre.ibm.com" -config $OPENSSL_PATH/ssl/openssl.cnf

RUN $OPENSSL_PATH/bin/openssl x509 -req -in server.csr -out server.crt -CA CA.crt -CAkey CA.key -CAcreateserial -days 365

RUN cat server.crt > qsc-ca-chain.crt
RUN cat CA.crt >> qsc-ca-chain.crt

# SKIP the steps to test connection

 ENV HTTPD_PATH $WORKSPACE/httpd
 ENV HTTPD_VERSION 2.4.57
 ENV APR_VERSION 1.7.4
 ENV APRU_VERSION 1.6.3
 ENV APR_MIRROR="https://dlcdn.apache.org"

 WORKDIR $WORKSPACE
 # do this at top
 #sudo apt install libexpat1-dev libpcre3 libpcre3-dev
 RUN wget https://dlcdn.apache.org/apr/apr-1.7.4.tar.gz && tar xzvf apr-1.7.4.tar.gz
 RUN wget https://dlcdn.apache.org/apr/apr-util-1.6.3.tar.gz && tar xzvf apr-util-1.6.3.tar.gz
 RUN wget --trust-server-names "https://archive.apache.org/dist/httpd/httpd-2.4.57.tar.gz" && tar -zxvf httpd-2.4.57.tar.gz
 
 # RUN sed -i "s/\$RM \"\$cfgfile\"/\$RM -f \"\$cfgfile\"/g" apr-1.7.4/configure
 # RUN cd apr-1.7.4 && ./configure --prefix=$BUILD_DIR  && make && make install
 # Removed architecture statement
 # RUN cd apr-util-1.6.3 && ./configure x86_64-pc-linux-gnu --with-crypto --with-openssl=${OPENSSL_PATH} --with-apr=/usr/local/apr && make && make install
 #RUN cd apr-util-1.6.3 && ./configure --prefix=$BUILD_DIR --with-crypto --with-openssl=${OPENSSL_PATH} --with-apr=$BUILD_DIR && make && make install

 WORKDIR $WORKSPACE/httpd-${HTTPD_VERSION}
  
 RUN mkdir -p srclib
 RUN mv ../apr-1.7.4 srclib/apr
 RUN mv ../apr-util-1.6.3 srclib/apr-util

 #RUN ./configure --prefix=${HTTPD_PATH} \
 #        --enable-debugger-mode \
 #        --enable-ssl --with-ssl=${OPENSSL_PATH} \
 #        --enable-ssl-staticlib-deps \
 #        --enable-mods-static=ssl && \
 #        --with-apr=$BUILD_DIR
 RUN ./configure --prefix=${HTTPD_PATH} \
         --enable-debugger-mode \
         --enable-ssl --with-ssl=${OPENSSL_PATH} \
         --enable-ssl-staticlib-deps \
         --enable-mods-static=ssl \
         --with-included-apr
 RUN make && make install;

 # NOTE - https://httpd.apache.org/docs/2.4/install.html
 # need to correctly specify APR and APR-util