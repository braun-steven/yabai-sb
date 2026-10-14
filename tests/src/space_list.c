static uint64_t space_list_test_neighbour(uint64_t sid, int offset)
{
    static uint64_t space_list[] = { 3, 7, 9 };
    return space_list_neighbour(space_list, array_count(space_list), sid, offset);
}

TEST_FUNC(space_list_navigation,
{
    TEST_CHECK((int) space_list_test_neighbour(7, -1), 3);
    TEST_CHECK((int) space_list_test_neighbour(7, 1), 9);
    TEST_CHECK((int) space_list_test_neighbour(3, -1), 0);
    TEST_CHECK((int) space_list_test_neighbour(9, 1), 0);
    TEST_CHECK((int) space_list_test_neighbour(5, 1), 0);
    TEST_CHECK((int) space_list_test_neighbour(5, -1), 0);

    uint64_t space_list[3];
    space_list[0] = 3; space_list[1] = 7; space_list[2] = 9;
    TEST_CHECK(space_list_index_of(space_list, 3, 9), 2);
    TEST_CHECK(space_list_index_of(space_list, 3, 4), -1);
    TEST_CHECK(space_list_index_of(NULL, 0, 4), -1);
});
