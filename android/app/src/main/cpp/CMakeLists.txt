cmake_minimum_required(VERSION 3.18.1)
project("pocket_aero" C CXX)

set(RTL_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/librtlsdr")

# ── libusb-android (static) ───────────────────────────────────────────────────
set(LIBUSB_SRC
    ${RTL_ROOT}/libusb/libusb/core.c
    ${RTL_ROOT}/libusb/libusb/descriptor.c
    ${RTL_ROOT}/libusb/libusb/hotplug.c
    ${RTL_ROOT}/libusb/libusb/io.c
    ${RTL_ROOT}/libusb/libusb/strerror.c
    ${RTL_ROOT}/libusb/libusb/sync.c
    ${RTL_ROOT}/libusb/libusb/os/linux_netlink.c
    ${RTL_ROOT}/libusb/libusb/os/linux_usbfs.c
    ${RTL_ROOT}/libusb/libusb/os/poll_posix.c
    ${RTL_ROOT}/libusb/libusb/os/threads_posix.c)

find_library(LOG_LIB log)

add_library(usb_android STATIC ${LIBUSB_SRC})
target_include_directories(usb_android PUBLIC
    ${RTL_ROOT}/libusb/libusb
    ${RTL_ROOT}/libusb/android)
target_compile_options(usb_android PRIVATE -Wall -O2 -Wno-unused-parameter)
target_link_libraries(usb_android ${LOG_LIB})

# ── librtlsdr (static) ───────────────────────────────────────────────────────
set(LIBRTLSDR_SRC
    ${RTL_ROOT}/src/librtlsdr.c
    ${RTL_ROOT}/src/tuner_e4k.c
    ${RTL_ROOT}/src/tuner_fc0012.c
    ${RTL_ROOT}/src/tuner_fc0013.c
    ${RTL_ROOT}/src/tuner_fc2580.c
    ${RTL_ROOT}/src/tuner_r82xx.c
    ${RTL_ROOT}/src/convenience/convenience.c)

add_library(rtlsdr_static STATIC ${LIBRTLSDR_SRC})
target_include_directories(rtlsdr_static PUBLIC  ${RTL_ROOT}/include)
target_include_directories(rtlsdr_static PRIVATE ${RTL_ROOT}/libusb/libusb)
target_compile_options(rtlsdr_static PRIVATE -Wall -O2 -Wno-unused-parameter)
target_link_libraries(rtlsdr_static usb_android ${LOG_LIB})

# ── multimon-ng sources (pager decoders) ─────────────────────────────────────
set(MULTIMON_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/multimon-ng")
set(MULTIMON_SRC
    ${MULTIMON_ROOT}/pocsag.c
    ${MULTIMON_ROOT}/demod_poc5.c
    ${MULTIMON_ROOT}/demod_poc12.c
    ${MULTIMON_ROOT}/demod_poc24.c
    ${MULTIMON_ROOT}/demod_flex.c
    ${MULTIMON_ROOT}/demod_flex_next.c
    ${MULTIMON_ROOT}/bch.c
    ${MULTIMON_ROOT}/costabf.c
    ${MULTIMON_ROOT}/cJSON.c)

# ── librf_studio_sdr (shared — loaded by Dart FFI) ───────────────────────────
set(JAERO_DSP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/jaero_dsp")

# ── libacars (static, ACARS message decoding) ───────────────────────────────
set(LIBACARS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/libacars/libacars")
file(GLOB LIBACARS_SRC
    ${LIBACARS_DIR}/*.c
    ${LIBACARS_DIR}/asn1/*.c)
add_library(libacars_static STATIC ${LIBACARS_SRC})
target_include_directories(libacars_static PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/libacars)
target_include_directories(libacars_static PRIVATE ${LIBACARS_DIR})
target_compile_options(libacars_static PRIVATE -Wall -O2 -Wno-unused-parameter)
find_library(ZLIB_LIB z)
if(ZLIB_LIB)
    target_link_libraries(libacars_static ${ZLIB_LIB})
endif()

# ── mbelib AMBE vocoder (static, compiled into rf_studio_sdr) ─────────────────
set(MBELIB_DIR "/home/rose/Compiled/AndAERO/libaeroambe/mbelib-master")
set(MBELIB_SRC
    ${MBELIB_DIR}/ambe4800x3600.c
    ${MBELIB_DIR}/ecc.c
    ${MBELIB_DIR}/mbelib.c)

set(JAERO_DSP_SRC
    ${JAERO_DSP_DIR}/DSP.cpp
    ${JAERO_DSP_DIR}/oqpskdemodulator.cpp
    ${JAERO_DSP_DIR}/burstmskdemodulator.cpp
    ${JAERO_DSP_DIR}/burstoqpskdemodulator.cpp
    ${JAERO_DSP_DIR}/mskdemodulator.cpp
    ${JAERO_DSP_DIR}/aerol.cpp
    ${JAERO_DSP_DIR}/jconvolutionalcodec.cpp
    ${JAERO_DSP_DIR}/coarsefreqestimate.cpp
    ${JAERO_DSP_DIR}/fftwrapper.cpp
    ${JAERO_DSP_DIR}/fftrwrapper.cpp
    ${JAERO_DSP_DIR}/jfft.cpp
    ${JAERO_DSP_DIR}/jaero_demod.cpp)

# Vendored libcorrect
set(LIBCORRECT_DIR "${JAERO_DSP_DIR}/libcorrect")
set(LIBCORRECT_SRC
    ${LIBCORRECT_DIR}/src/convolutional/convolutional.c
    ${LIBCORRECT_DIR}/src/convolutional/decode.c
    ${LIBCORRECT_DIR}/src/convolutional/encode.c
    ${LIBCORRECT_DIR}/src/convolutional/bit.c
    ${LIBCORRECT_DIR}/src/convolutional/lookup.c
    ${LIBCORRECT_DIR}/src/convolutional/metric.c
    ${LIBCORRECT_DIR}/src/convolutional/history_buffer.c
    ${LIBCORRECT_DIR}/src/convolutional/error_buffer.c
    ${LIBCORRECT_DIR}/src/reed-solomon/decode.c
    ${LIBCORRECT_DIR}/src/reed-solomon/encode.c
    ${LIBCORRECT_DIR}/src/reed-solomon/polynomial.c
    ${LIBCORRECT_DIR}/src/reed-solomon/reed-solomon.c
    ${LIBCORRECT_DIR}/src/fec_shim.c)

add_library(rf_studio_sdr SHARED
    rfstudio_sdr.c
    pager_hackrf.c
    signal_gen.c
    ${JAERO_DSP_SRC}
    ${LIBCORRECT_SRC}
    ${MULTIMON_SRC}
    ${MBELIB_SRC})
target_include_directories(rf_studio_sdr PRIVATE
    ${RTL_ROOT}/include
    ${MULTIMON_ROOT}
    ${JAERO_DSP_DIR}
    ${LIBCORRECT_DIR}/include
    ${MBELIB_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/libacars)
target_compile_options(rf_studio_sdr PRIVATE
    -Wall -O2 -ffast-math -fpermissive
    -DMAX_VERBOSE_LEVEL=0
    -DCHARSET_UTF8
    -DNO_X11
    -DNO_SDL3
    -DDUMMY_AUDIO)
target_link_libraries(rf_studio_sdr rtlsdr_static usb_android ${LOG_LIB} m aaudio libacars_static ${ZLIB_LIB})

# ── librtl433_ffi (shared — loaded by Dart FFI for 433 MHz decoding) ─────────
set(RTL433_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/rtl_433")

file(GLOB RTL433_CORE_SRC   "${RTL433_ROOT}/src/*.c")
file(GLOB RTL433_DEVICE_SRC "${RTL433_ROOT}/src/devices/*.c")

add_library(rtl433_ffi SHARED
    ${RTL433_CORE_SRC}
    ${RTL433_DEVICE_SRC})

target_include_directories(rtl433_ffi PRIVATE
    ${RTL433_ROOT}/include
    ${RTL433_ROOT}/src
    ${RTL_ROOT}/include)

target_compile_definitions(rtl433_ffi PRIVATE
    _GNU_SOURCE
    THREADS
    MG_ENABLE_IPV6=1
    ANDROID
    RTLSDR
    NDEBUG)

target_compile_options(rtl433_ffi PRIVATE
    -std=c99
    -O2 -ffast-math
    -Wall -Wno-unused-parameter -Wno-unused-function
    -Wno-sign-compare -Wno-pedantic)

target_link_libraries(rtl433_ffi rtlsdr_static usb_android ${LOG_LIB} m)

# ── libscm_decoder (shared — Smart Electric Meter SCM decoder) ───────────────
add_library(scm_decoder SHARED scm_lib.c)
target_include_directories(scm_decoder PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${RTL_ROOT}/include
    ${RTL_ROOT}/libusb/libusb
    ${RTL_ROOT}/libusb/android)
target_compile_options(scm_decoder PRIVATE -Wall -O2 -Wno-unused-parameter)
target_link_libraries(scm_decoder rtlsdr_static usb_android ${LOG_LIB})

# ── libdect_ffi (shared — DECT decoder) ──────────────────────────────────────
add_library(dect_ffi SHARED
    dect_ffi.cpp
    packet_receiver.cpp
    packet_decoder.cpp
    g72x.c)

target_include_directories(dect_ffi PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${RTL_ROOT}/include
    ${RTL_ROOT}/libusb/libusb
    ${RTL_ROOT}/libusb/android)

set_target_properties(dect_ffi PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON)

# ── libadsb_ffi (shared — ADS-B 1090 MHz decoder) ────────────────────────────
add_library(adsb_ffi SHARED
    adsb_ffi.cpp
    dump1090/cpr.c
    dump1090/ais_charset.c)

target_include_directories(adsb_ffi PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${RTL_ROOT}/include
    ${RTL_ROOT}/libusb/libusb
    ${RTL_ROOT}/libusb/android)

set_target_properties(adsb_ffi PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON)

target_compile_options(adsb_ffi PRIVATE
    -O2 -ffast-math -Wall -Wno-unused-parameter)

target_link_libraries(adsb_ffi
    rtlsdr_static
    usb_android
    android
    ${LOG_LIB}
    m)

target_compile_options(dect_ffi PRIVATE
    -O2 -ffast-math
    -Wall -Wno-unused-parameter)

target_link_libraries(dect_ffi rtlsdr_static usb_android ${LOG_LIB} m)
