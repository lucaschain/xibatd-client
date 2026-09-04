#include <gtest/gtest.h>

#include "framework/core/config.h"
#include "framework/otml/otmlnode.h"

TEST(ConfigChange, NotifiesForMutations)
{
    Config config;
    int changeCount = 0;
    config.setChangeCallback([&changeCount] { ++changeCount; });

    config.setValue("value", "one");
    EXPECT_EQ(changeCount, 1);

    config.setList("list", { "one", "two" });
    EXPECT_EQ(changeCount, 2);

    const auto node = OTMLNode::create("source", "node");
    config.setNode("node", node);
    EXPECT_EQ(changeCount, 3);

    config.mergeNode("merged", node);
    EXPECT_EQ(changeCount, 4);

    config.remove("missing");
    EXPECT_EQ(changeCount, 4);

    config.remove("value");
    EXPECT_EQ(changeCount, 5);

    config.clear();
    EXPECT_EQ(changeCount, 6);
}
