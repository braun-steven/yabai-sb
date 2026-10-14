static struct rule window_rules_test_rule(char *app, char *subrole, uint16_t flags)
{
    struct rule rule = { .flags = flags | RULE_APP_VALID };
    regcomp(&rule.app_regex, app, REG_EXTENDED);

    if (subrole) {
        regcomp(&rule.subrole_regex, subrole, REG_EXTENDED);
        rule_set_flag(&rule, RULE_SUBROLE_VALID);
    }

    return rule;
}

static void window_rules_test_free(struct window_manager *wm)
{
    for (int i = 0; i < buf_len(wm->rules); ++i) {
        rule_destroy(&wm->rules[i]);
    }
    buf_free(wm->rules);
}

TEST_FUNC(window_rules_combine_matching,
{
    struct application application = { .name = "Safari" };
    struct window window = { .application = &application };
    struct window_manager wm = {0};

    // NOTE: without a subrole pattern a rule does not match a dialog
    struct rule any = window_rules_test_rule("^Safari$", NULL, 0);
    any.effects.sid = 4;
    buf_push(wm.rules, any);

    struct rule dialog = window_rules_test_rule("^Safari$", "^AXDialog$", 0);
    dialog.effects.sticky = RULE_PROP_ON;
    dialog.effects.scratchpad = string_copy("notes");
    buf_push(wm.rules, dialog);

    struct rule other_app = window_rules_test_rule("^Mail$", "^AXDialog$", 0);
    other_app.effects.mff = RULE_PROP_ON;
    buf_push(wm.rules, other_app);

    struct rule one_shot = window_rules_test_rule("^Safari$", "^AXDialog$", RULE_ONE_SHOT);
    one_shot.effects.layer = LAYER_ABOVE;
    rule_effects_set_flag(&one_shot.effects, RULE_LAYER);
    buf_push(wm.rules, one_shot);

    struct rule_effects effects = {0};
    TEST_CHECK(window_manager_combine_matching_rule_effects(&wm, &window, "", "AXWindow", "AXDialog", false, false, &effects), true);
    TEST_CHECK((int) effects.sid, 0);
    TEST_CHECK(effects.sticky, RULE_PROP_ON);
    TEST_CHECK(effects.mff, RULE_PROP_UD);
    TEST_CHECK(rule_effects_check_flag(&effects, RULE_LAYER), false);
    TEST_CHECK(strcmp(effects.scratchpad, "notes"), 0);
    TEST_CHECK(rule_check_flag(&wm.rules[3], RULE_ONE_SHOT_REMOVE), false);
    free(effects.scratchpad);

    // NOTE: one-shot rules only apply to new windows, and are then marked for removal
    effects = (struct rule_effects) {0};
    TEST_CHECK(window_manager_combine_matching_rule_effects(&wm, &window, "", "AXWindow", "AXDialog", true, false, &effects), true);
    TEST_CHECK(rule_effects_check_flag(&effects, RULE_LAYER), true);
    TEST_CHECK(rule_check_flag(&wm.rules[3], RULE_ONE_SHOT_REMOVE), true);
    free(effects.scratchpad);

    window_manager_remove_one_shot_rules(&wm);
    TEST_CHECK(buf_len(wm.rules), 3);

    // NOTE: a window managed by a rule matches rules without a subrole pattern
    window_set_rule_flag(&window, WINDOW_RULE_MANAGED);
    effects = (struct rule_effects) {0};
    TEST_CHECK(window_manager_combine_matching_rule_effects(&wm, &window, "", "AXWindow", "AXDialog", false, false, &effects), true);
    TEST_CHECK((int) effects.sid, 4);
    free(effects.scratchpad);

    window_rules_test_free(&wm);
});

TEST_FUNC(window_rules_manage_round,
{
    struct application application = { .name = "Safari" };
    struct window window = { .application = &application };
    struct window_manager wm = {0};

    // NOTE: in the manage round only rules that make a window managed are limited to standard windows
    struct rule manage = window_rules_test_rule("^Safari$", NULL, 0);
    manage.effects.manage = RULE_PROP_ON;
    buf_push(wm.rules, manage);

    struct rule effects_only = window_rules_test_rule("^Safari$", NULL, 0);
    effects_only.effects.sticky = RULE_PROP_ON;
    buf_push(wm.rules, effects_only);

    struct rule_effects effects = {0};
    TEST_CHECK(window_manager_combine_matching_rule_effects(&wm, &window, "", "AXWindow", "AXDialog", false, true, &effects), true);
    TEST_CHECK(effects.manage, RULE_PROP_UD);
    TEST_CHECK(effects.sticky, RULE_PROP_ON);

    effects = (struct rule_effects) {0};
    TEST_CHECK(window_manager_combine_matching_rule_effects(&wm, &window, "", "AXWindow", "AXStandardWindow", false, true, &effects), true);
    TEST_CHECK(effects.manage, RULE_PROP_ON);

    application.name = "Mail";
    effects = (struct rule_effects) {0};
    TEST_CHECK(window_manager_combine_matching_rule_effects(&wm, &window, "", "AXWindow", "AXStandardWindow", false, true, &effects), false);

    window_rules_test_free(&wm);
});
