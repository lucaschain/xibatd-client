set(PROTOCOL_TEST_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/protocolgame_player_stats_test.cpp
)

otclient_add_gtest(otclient_protocol_tests ${PROTOCOL_TEST_SOURCES})
