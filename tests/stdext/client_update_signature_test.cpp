#include <gtest/gtest.h>

#include "framework/util/crypt.h"

TEST(ClientUpdateSignatureTest, AcceptsTrustedKeyAndRejectsTampering)
{
    constexpr auto payload = "eGliYXQgdXBkYXRlciB2ZXJpZmljYXRpb24gdGVzdA==";
    constexpr auto signature = "jVXevCBZ/baqGJodx0tvPmvpEuWmdFU0vkNJt3Uk9fWyEGXYF6/oM765w8KmtAaopY82XeN8XnfTQA0EpT8gBQ==";

    EXPECT_TRUE(g_crypt.verifyClientUpdateSignature("xibat-client-2026-01", payload, signature));
    EXPECT_FALSE(g_crypt.verifyClientUpdateSignature("unknown-key", payload, signature));
    EXPECT_FALSE(g_crypt.verifyClientUpdateSignature("xibat-client-2026-01", "dGFtcGVyZWQ=", signature));
}
