#!/bin/sh

# Sets the target folders and the final framework product.
FMK_NAME=AppCenterAnalytics
TGT_NAME=${FMK_NAME}IOS

# Install dir will be the final output to the framework.
# The following line create it in the root folder of the current project.
PRODUCTS_DIR=${SRCROOT}/../AppCenter-SDK-Apple/iOS
INSTALL_DIR=${PRODUCTS_DIR}/${FMK_NAME}.framework

# Working dir will be deleted after the framework creation.
WRK_DIR=build
DEVICE_DIR=${WRK_DIR}/Release-iphoneos
SIMULATOR_DIR=${WRK_DIR}/Release-iphonesimulator

# Make sure we're inside $SRCROOT
cd "${SRCROOT}"

# Cleaning previous build
xcodebuild -project "${FMK_NAME}.xcodeproj" -configuration "Release" -target "${TGT_NAME}" clean

# Building both architectures.
xcodebuild -project "${FMK_NAME}.xcodeproj" -configuration "Release" -target "${TGT_NAME}" -sdk iphoneos
xcodebuild -project "${FMK_NAME}.xcodeproj" -configuration "Release" -target "${TGT_NAME}" -sdk iphonesimulator

# Cleaning the oldest.
if [ -d "${INSTALL_DIR}" ]
then
rm -rf "${INSTALL_DIR}"
fi

# Creates and renews the final product folder.
mkdir -p "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/Headers"
mkdir -p "${INSTALL_DIR}/Modules"

# Copy the swift import file
cp -f "${SRCROOT}/${FMK_NAME}/Support/iOS.modulemap" "${INSTALL_DIR}/Modules/module.modulemap"

# Copies the headers and resources files to the final product folder.
cp -R "${SRCROOT}/${WRK_DIR}/Release-iphoneos/include/${FMK_NAME}/" "${INSTALL_DIR}/Headers/"


# Uses the Lipo Tool to merge both binary files (i386 + armv6/armv7) into one Universal final product.
lipo -create "${DEVICE_DIR}/lib${FMK_NAME}.a" "${SIMULATOR_DIR}/lib${FMK_NAME}.a" -output "${INSTALL_DIR}/${FMK_NAME}"

rm -r "${WRK_DIR}"
