TEST_FUNC(label_list,
{
    struct label *list = NULL;

    label_set(&list, 4, string_copy("code"));
    label_set(&list, 5, string_copy("web"));
    TEST_CHECK(buf_len(list), 2);
    TEST_CHECK((int) label_find_name(list, "web")->id, 5);
    TEST_CHECK(strcmp(label_find_id(list, 4)->label, "code"), 0);

    // NOTE: a new name replaces the old name of an id
    label_set(&list, 4, string_copy("mail"));
    TEST_CHECK(buf_len(list), 2);
    TEST_CHECK(label_find_name(list, "code") == NULL, true);

    // NOTE: a name that is in use moves to the new id
    label_set(&list, 6, string_copy("web"));
    TEST_CHECK(buf_len(list), 2);
    TEST_CHECK(label_find_id(list, 5) == NULL, true);
    TEST_CHECK((int) label_find_name(list, "web")->id, 6);

    TEST_CHECK(label_remove_id(&list, 6), true);
    TEST_CHECK(label_remove_id(&list, 6), false);
    TEST_CHECK(label_remove_id(&list, 4), true);
    TEST_CHECK(buf_len(list), 0);

    buf_free(list);
});
