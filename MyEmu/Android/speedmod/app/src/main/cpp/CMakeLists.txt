cmake_minimum_required(VERSION 3.22.1)
project(speedhook)

find_package(shadowhook REQUIRED CONFIG)

add_library(speedhook SHARED speedhook.c)

find_library(log-lib log)
target_link_libraries(speedhook shadowhook::shadowhook ${log-lib})
