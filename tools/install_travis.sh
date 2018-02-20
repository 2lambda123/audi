#!/bin/bash
set -e -x

cd /audi
echo "Environment variables passed to docker from travis VM:"
echo ${BUILD_TYPE}
echo ${PATH_TO_PYTHON}
echo ${PYTHON_VERSION}

# Install gmp (before mpfr as its used by it)
curl https://gmplib.org/download/gmp/gmp-6.1.1.tar.bz2 > gmp-6.1.1.tar.bz2
tar xvf gmp-6.1.1.tar.bz2  > /dev/null 2>&1
cd gmp-6.1.1 > /dev/null 2>&1
./configure > /dev/null 2>&1
make > /dev/null 2>&1
make install > /dev/null 2>&1
cd ..


# Install mpfr
wget http://www.mpfr.org/mpfr-3.1.6/mpfr-3.1.6.tar.gz > /dev/null 2>&1
tar xvf mpfr-3.1.6.tar.gz > /dev/null 2>&1
cd mpfr-3.1.6
./configure > /dev/null 2>&1
make > /dev/null 2>&1
make install > /dev/null 2>&1
cd ..

# Compile and install boost
wget --no-check-certificate https://dl.bintray.com/boostorg/release/1.66.0/source/boost_1_66_0.tar.bz2 > /dev/null 2>&1
tar --bzip2 -xf /audi/boost_1_66_0.tar.bz2 > /dev/null 2>&1
cd boost_1_62_0
./bootstrap.sh > /dev/null 2>&1
# removing the wrongly detected python 2.4 (deletes 5 lines after the comment "# Python configuration" )
sed -i.bak -e '/# Python configuration/,+5d' ./project-config.jam
# Defining the correct locations for python and boost_python
if [[ "${PYTHON_VERSION}" != "2.7" ]]; then #python3
    export BOOST_PYTHON_LIB_NAME=libboost_python3.so
    echo "using python" >> project-config.jam
    echo "     : ${PYTHON_VERSION}" >> project-config.jam
    echo "     : ${PATH_TO_PYTHON}/bin/python"  >> project-config.jam
    # note the m is not there !!
    echo "     : ${PATH_TO_PYTHON}/include/python${PYTHON_VERSION}m"  >> project-config.jam
    echo "     : ${PATH_TO_PYTHON}/lib"  >> project-config.jam
    echo "     ;" >> project-config.jam
else #python2
    export BOOST_PYTHON_LIB_NAME=libboost_python.so
    echo "using python" >> project-config.jam
    echo "     : ${PYTHON_VERSION}" >> project-config.jam
    echo "     : ${PATH_TO_PYTHON}/bin/python"  >> project-config.jam
    echo "     : ${PATH_TO_PYTHON}/include/python${PYTHON_VERSION}"  >> project-config.jam
    echo "     : ${PATH_TO_PYTHON}/lib"  >> project-config.jam
    echo "     ;" >> project-config.jam
fi

# Add here the boost libraries that are needed
./b2 install cxxflags="-std=c++11" --with-python --with-serialization --with-iostreams --with-regex --with-chrono --with-timer --with-test --with-system > /dev/null 2>&1
cd ..

# Install cmake
wget --no-check-certificate https://cmake.org/files/v3.7/cmake-3.7.0.tar.gz > /dev/null 2>&1
tar xvf /audi/cmake-3.7.0.tar.gz > /dev/null 2>&1
cd cmake-3.7.0
./bootstrap > /dev/null 2>&1
make > /dev/null 2>&1
make install > /dev/null 2>&1
cd ..

# Install piranha
wget https://github.com/bluescarni/piranha/archive/v0.8.tar.gz > /dev/null 2>&1
tar xvf v0.8
cd piranha-0.8
mkdir build
cd build
cmake ../
make install > /dev/null 2>&1
cd ..
# Apply patch (TODO: remove and use latest piranha with the accepted PR)
wget --no-check-certificate https://raw.githubusercontent.com/darioizzo/piranha/22ab56da726df41ef18aa898e551af7415a32c25/src/thread_management.hpp
rm -f /usr/local/include/piranha/thread_management.hpp
cp thread_management.hpp /usr/local/include/piranha/

# Install and compile pyaudi
cd /audi
mkdir build
cd build
# The include directory for py3 is X.Xm, while for py2 is X.X
if [[ "${PYTHON_VERSION}" != "2.7" ]]; then
    cmake -DBUILD_PYAUDI=yes -DBUILD_TESTS=no -DCMAKE_INSTALL_PREFIX=/audi/local -DCMAKE_BUILD_TYPE=Release -DBoost_PYTHON_LIBRARY_RELEASE=/usr/local/lib/${BOOST_PYTHON_LIB_NAME} -DPYTHON_INCLUDE_DIR=${PATH_TO_PYTHON}/include/python${PYTHON_VERSION}m/ -DPYTHON_EXECUTABLE=${PATH_TO_PYTHON}/bin/python  ../
else
    cmake -DBUILD_PYAUDI=yes -DBUILD_TESTS=no -DCMAKE_INSTALL_PREFIX=/audi/local -DCMAKE_BUILD_TYPE=Release -DBoost_PYTHON_LIBRARY_RELEASE=/usr/local/lib/${BOOST_PYTHON_LIB_NAME} -DPYTHON_INCLUDE_DIR=${PATH_TO_PYTHON}/include/python${PYTHON_VERSION}/ -DPYTHON_EXECUTABLE=${PATH_TO_PYTHON}/bin/python  ../
fi
make
make install

# Compile wheels
cd /audi/build/wheel
cp -R /audi/local/lib/python${PYTHON_VERSION}/site-packages/pyaudi ./
# The following line is needed as a workaround to the auditwheel problem KeyError = .lib
# Using and compiling a null extension module (see manylinux_wheel_setup.py)
# fixes the issue (TODO: probably better ways?)
touch dummy.cpp

# We install required dependncies (do it here, do not let pip install do it)
${PATH_TO_PYTHON}/bin/pip install numpy
${PATH_TO_PYTHON}/bin/pip wheel ./ -w wheelhouse/
# Bundle external shared libraries into the wheels (only py35 has auditwheel)
/opt/python/cp35-cp35m/bin/auditwheel repair wheelhouse/pyaudi*.whl -w ./wheelhouse2/
# Install packages (not sure what --no-index -f does, should also work without, but just in case)
${PATH_TO_PYTHON}/bin/pip install pyaudi --no-index -f wheelhouse2
# Test
cd /
${PATH_TO_PYTHON}/bin/python -c "from pyaudi import test; test.run_test_suite()"

# Upload in PyPi
# This variable will contain something if this is a tagged build (vx.y.z), otherwise it will be empty.
export AUDI_RELEASE_VERSION=`echo "${TRAVIS_TAG}"|grep -E 'v[0-9]+\.[0-9]+.*'|cut -c 2-`
if [[ "${AUDI_RELEASE_VERSION}" != "" ]]; then
    cd audi/build/wheel
    echo "Release build detected, uploading to PyPi."
    ${PATH_TO_PYTHON}/bin/pip install twine
    ${PATH_TO_PYTHON}/bin/twine upload -u darioizzo wheelhouse2/pyaudi*.whl
fi
