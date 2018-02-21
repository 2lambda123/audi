#!/usr/bin/env bash

# Echo each command
set -x

# Exit on error.
set -e

CMAKE_VERSION="3.10.0"
EIGEN3_VERSION="3.3.4"
BOOST_VERSION="1.65.0"
NLOPT_VERSION="2.4.2"

if [[ ${AUDI_BUILD} == *36 ]]; then
	PYTHON_DIR="cp36-cp36m"
elif [[ ${AUDI_BUILD} == *35 ]]; then
	PYTHON_DIR="cp35-cp35m"
elif [[ ${AUDI_BUILD} == *34 ]]; then
	PYTHON_DIR="cp34-cp34m"
elif [[ ${AUDI_BUILD} == *27 ]]; then
	PYTHON_DIR="cp27-cp27mu"
else
	echo "Invalid build type: ${AUDI_BUILD}"
	exit 1
fi

# HACK: for python 3.x, the include directory
# is called 'python3.xm' rather than just 'python3.x'.
# This confuses the build system of Boost.Python, thus
# we create a symlink to 'python3.x'.
cd /opt/python/${PYTHON_DIR}/include
PY_INCLUDE_DIR_NAME=`ls`
# If the include dir ends with 'm', create a symlink
# without the 'm'.
if [[ $PY_INCLUDE_DIR_NAME == *m ]]; then
	ln -s $PY_INCLUDE_DIR_NAME `echo $PY_INCLUDE_DIR_NAME|sed 's/.$//'`
fi

cd
mkdir install
cd install

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

# Install CMake
wget https://github.com/Kitware/CMake/archive/v${CMAKE_VERSION}.tar.gz --no-verbose
tar xzf v${CMAKE_VERSION}
cd CMake-${CMAKE_VERSION}/
./configure > /dev/null
gmake -j2 > /dev/null
gmake install > /dev/null
cd ..

# Install Boost
wget https://downloads.sourceforge.net/project/boost/boost/${BOOST_VERSION}/boost_`echo ${BOOST_VERSION}|tr "." "_"`.tar.bz2 --no-verbose
tar xjf boost_`echo ${BOOST_VERSION}|tr "." "_"`.tar.bz2
cd boost_`echo ${BOOST_VERSION}|tr "." "_"`
sh bootstrap.sh --with-python=/opt/python/${PYTHON_DIR}/bin/python > /dev/null
./bjam --toolset=gcc link=shared threading=multi cxxflags="-std=c++11" variant=release --with-python -j2 install > /dev/null
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
