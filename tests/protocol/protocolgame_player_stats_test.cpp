#include <gtest/gtest.h>

#include "client/game.h"
#include "client/protocolcodes.h"
#include "client/protocolgame.h"
#include "framework/net/inputmessage.h"

class ProtocolGameTestAccess
{
public:
    static uint16_t parsePlayerSoul(const InputMessagePtr& message)
    {
        return ProtocolGame::parsePlayerSoul(message);
    }
};

namespace {

InputMessagePtr makeSoulMessage(const uint16_t soul, const bool doubleSoul)
{
    std::string buffer;
    buffer.push_back(static_cast<char>(soul & 0xFF));
    if (doubleSoul)
        buffer.push_back(static_cast<char>(soul >> 8));
    buffer.push_back(static_cast<char>(Proto::GameServerPlayerSkills));

    const auto message = std::make_shared<InputMessage>();
    message->setBuffer(buffer);
    message->setReadPos(message->getMaxHeaderSize());
    return message;
}

class ProtocolGamePlayerStatsTest : public testing::Test
{
protected:
    void SetUp() override
    {
        g_game.enableFeature(Otc::GameSoul);
        g_game.disableFeature(Otc::GameDoubleSoul);
    }

    void TearDown() override
    {
        g_game.disableFeature(Otc::GameSoul);
        g_game.disableFeature(Otc::GameDoubleSoul);
    }
};

TEST_F(ProtocolGamePlayerStatsTest, ParsesXibatUint16SoulWithoutConsumingNextOpcode)
{
    g_game.enableFeature(Otc::GameDoubleSoul);
    const auto message = makeSoulMessage(0x1234, true);

    EXPECT_EQ(ProtocolGameTestAccess::parsePlayerSoul(message), 0x1234);
    ASSERT_EQ(message->getUnreadSize(), 1);
    EXPECT_EQ(message->getU8(), Proto::GameServerPlayerSkills);
    EXPECT_TRUE(message->eof());
}

TEST_F(ProtocolGamePlayerStatsTest, PreservesLegacyUint8SoulParsing)
{
    const auto message = makeSoulMessage(0x7F, false);

    EXPECT_EQ(ProtocolGameTestAccess::parsePlayerSoul(message), 0x7F);
    ASSERT_EQ(message->getUnreadSize(), 1);
    EXPECT_EQ(message->getU8(), Proto::GameServerPlayerSkills);
    EXPECT_TRUE(message->eof());
}

} // namespace
