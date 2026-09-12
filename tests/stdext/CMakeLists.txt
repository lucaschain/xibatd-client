set(STRING_ENCODING_TEST_SOURCES
	${CMAKE_CURRENT_SOURCE_DIR}/client_update_signature_test.cpp
	${CMAKE_CURRENT_SOURCE_DIR}/string_encoding_test.cpp
)

otclient_add_gtest(otclient_string_encoding_tests ${STRING_ENCODING_TEST_SOURCES})
