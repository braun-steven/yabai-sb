static bool border_test_rect(CGRect rect, float x, float y, float w, float h)
{
    return rect.origin.x == x && rect.origin.y == y && rect.size.width == w && rect.size.height == h;
}

TEST_FUNC(border_edge_frames_split,
{
    CGRect edge[BORDER_EDGE_COUNT];

    border_edge_frames(CGRectMake(100, 200, 800, 600), 6.0f, 10.0f, edge);
    TEST_CHECK(border_test_rect(edge[BORDER_EDGE_TOP],      94, 194, 812, 16), true);
    TEST_CHECK(border_test_rect(edge[BORDER_EDGE_BOTTOM],   94, 790, 812, 16), true);
    TEST_CHECK(border_test_rect(edge[BORDER_EDGE_LEFT],     94, 210,   7, 580), true);
    TEST_CHECK(border_test_rect(edge[BORDER_EDGE_RIGHT],   899, 210,   7, 580), true);

    border_edge_frames(CGRectMake(0, 0, 400, 20), 6.0f, 10.0f, edge);
    TEST_CHECK(border_test_rect(edge[BORDER_EDGE_TOP],      -6, -6, 412, 16), true);
    TEST_CHECK(border_test_rect(edge[BORDER_EDGE_BOTTOM],   -6, 10, 412, 16), true);
    TEST_CHECK((int) edge[BORDER_EDGE_LEFT].size.height, 0);
    TEST_CHECK((int) edge[BORDER_EDGE_RIGHT].size.height, 0);

    border_edge_frames(CGRectMake(0, 0, 400, 21), 4.0f, 12.5f, edge);
    TEST_CHECK((int) edge[BORDER_EDGE_TOP].size.height, 14);
    TEST_CHECK((int) edge[BORDER_EDGE_BOTTOM].size.height, 15);
    TEST_CHECK((int) edge[BORDER_EDGE_LEFT].size.height, 0);
});
