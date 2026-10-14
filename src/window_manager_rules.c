//
// NOTE: Applying rules to windows. A window passes through two rounds: the manage round decides whether
// the window is managed, the effects round applies everything else to eligible windows.
//

void window_manager_query_window_rules(FILE *rsp)
{
    TIME_FUNCTION;

    fprintf(rsp, "[");
    for (int i = 0; i < buf_len(g_window_manager.rules); ++i) {
        struct rule *rule = &g_window_manager.rules[i];
        rule_serialize(rsp, rule, i);
        if (i < buf_len(g_window_manager.rules) - 1) fprintf(rsp, ",");
    }
    fprintf(rsp, "]\n");
}

bool window_manager_rule_matches_window(struct rule *rule, struct window *window, char *window_title, char *window_role, char *window_subrole)
{
    int regex_match_app = rule_check_flag(rule, RULE_APP_EXCLUDE) ? REGEX_MATCH_YES : REGEX_MATCH_NO;
    if (regex_match(rule_check_flag(rule, RULE_APP_VALID), &rule->app_regex, window->application->name) == regex_match_app) return false;

    int regex_match_title = rule_check_flag(rule, RULE_TITLE_EXCLUDE) ? REGEX_MATCH_YES : REGEX_MATCH_NO;
    if (regex_match(rule_check_flag(rule, RULE_TITLE_VALID), &rule->title_regex, window_title) == regex_match_title) return false;

    int regex_match_role = rule_check_flag(rule, RULE_ROLE_EXCLUDE) ? REGEX_MATCH_YES : REGEX_MATCH_NO;
    if (regex_match(rule_check_flag(rule, RULE_ROLE_VALID), &rule->role_regex, window_role) == regex_match_role) return false;

    int regex_match_subrole = rule_check_flag(rule, RULE_SUBROLE_EXCLUDE) ? REGEX_MATCH_YES : REGEX_MATCH_NO;
    if (regex_match(rule_check_flag(rule, RULE_SUBROLE_VALID), &rule->subrole_regex, window_subrole) == regex_match_subrole) return false;

    return true;
}

void window_manager_apply_manage_rule_effects_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, struct rule_effects *effects)
{
    if (effects->manage == RULE_PROP_ON) {
        window_set_rule_flag(window, WINDOW_RULE_MANAGED);
        window_manager_make_window_floating(sm, wm, window, false, true);
    } else if (effects->manage == RULE_PROP_OFF) {
        window_clear_rule_flag(window, WINDOW_RULE_MANAGED);
        window_manager_make_window_floating(sm, wm, window, true, true);
    }
}

void window_manager_apply_rule_effects_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, struct rule_effects *effects)
{
    if (effects->sid || effects->did) {
        if (!window_is_fullscreen(window) && !space_is_fullscreen(window_space(window->id))) {
            uint64_t sid = effects->sid ? effects->sid : display_space_id(effects->did);
            window_manager_send_window_to_space(sm, wm, window, sid, true);
            if (rule_effects_check_flag(effects, RULE_FOLLOW_SPACE) || effects->fullscreen == RULE_PROP_ON) {
                space_manager_focus_space(sid);
            }
        }
    }

    if (effects->sticky == RULE_PROP_ON) {
        window_manager_make_window_sticky(sm, wm, window, true);
    } else if (effects->sticky == RULE_PROP_OFF) {
        window_manager_make_window_sticky(sm, wm, window, false);
    }

    if (effects->mff == RULE_PROP_ON) {
        window_set_rule_flag(window, WINDOW_RULE_MFF);
        window_set_rule_flag(window, WINDOW_RULE_MFF_VALUE);
    } else if (effects->mff == RULE_PROP_OFF) {
        window_set_rule_flag(window, WINDOW_RULE_MFF);
        window_clear_rule_flag(window, WINDOW_RULE_MFF_VALUE);
    }

    if (rule_effects_check_flag(effects, RULE_LAYER)) {
        window_manager_set_window_layer(window, effects->layer);
    }

    if (rule_effects_check_flag(effects, RULE_OPACITY) && in_range_ii(effects->opacity, 0.0f, 1.0f)) {
        window->opacity = effects->opacity;
        window_manager_set_opacity(wm, window, effects->opacity);
    }

    if (effects->fullscreen == RULE_PROP_ON) {
        AXUIElementSetAttributeValue(window->ref, kAXFullscreenAttribute, kCFBooleanTrue);
        window_set_rule_flag(window, WINDOW_RULE_FULLSCREEN);
    }

    if (effects->scratchpad) {
        char *scratchpad = string_copy(effects->scratchpad);
        if (!window_manager_set_scratchpad_for_window(wm, window, scratchpad)) {
            free(scratchpad);
        }
    }

    if (effects->grid[0] != 0 && effects->grid[1] != 0) {
        window_manager_apply_grid(sm, wm, window, effects->grid[0], effects->grid[1], effects->grid[2], effects->grid[3], effects->grid[4], effects->grid[5]);
    }
}

//
// NOTE: A rule without a role or subrole pattern only matches standard windows (AXWindow, AXStandardWindow)
// when it makes a window managed (manage round), or when the window is not managed by a rule (effects round).
//

static inline bool window_manager_rule_skips_nonstandard_window(struct rule *rule, char *window_role, char *window_subrole)
{
    if (!rule_check_flag(rule, RULE_ROLE_VALID)    && !string_equals(window_role,    "AXWindow"))         return true;
    if (!rule_check_flag(rule, RULE_SUBROLE_VALID) && !string_equals(window_subrole, "AXStandardWindow")) return true;
    return false;
}

//
// NOTE: Combines the effects of every matching rule into effects, in the order the rules were added, and marks
// matching one-shot rules for removal. The caller frees effects->scratchpad.
//

static bool window_manager_combine_matching_rule_effects(struct window_manager *wm, struct window *window, char *window_title, char *window_role, char *window_subrole, bool one_shot_rules, bool manage_round, struct rule_effects *effects)
{
    bool match = false;

    for (int i = 0; i < buf_len(wm->rules); ++i) {
        struct rule *rule = &wm->rules[i];

        if (!one_shot_rules && rule_check_flag(rule, RULE_ONE_SHOT)) continue;
        if (!window_manager_rule_matches_window(rule, window, window_title, window_role, window_subrole)) continue;

        bool standard_only = manage_round ? rule->effects.manage == RULE_PROP_ON : !window_check_rule_flag(window, WINDOW_RULE_MANAGED);
        if (standard_only && window_manager_rule_skips_nonstandard_window(rule, window_role, window_subrole)) continue;

        match = true;
        rule_combine_effects(&rule->effects, effects);

        if (rule_check_flag(rule, RULE_ONE_SHOT)) rule_set_flag(rule, RULE_ONE_SHOT_REMOVE);
    }

    return match;
}

void window_manager_apply_manage_rules_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, char *window_title, char *window_role, char *window_subrole, bool one_shot_rules)
{
    struct rule_effects effects = {0};

    if (window_manager_combine_matching_rule_effects(wm, window, window_title, window_role, window_subrole, one_shot_rules, true, &effects)) {
        window_manager_apply_manage_rule_effects_to_window(sm, wm, window, &effects);
    }

    if (effects.scratchpad) free(effects.scratchpad);
}

void window_manager_apply_rules_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, char *window_title, char *window_role, char *window_subrole, bool one_shot_rules)
{
    struct rule_effects effects = {0};

    if (window_manager_combine_matching_rule_effects(wm, window, window_title, window_role, window_subrole, one_shot_rules, false, &effects)) {
        window_manager_apply_rule_effects_to_window(sm, wm, window, &effects);
    }

    if (effects.scratchpad) free(effects.scratchpad);
}

//
// NOTE: One-shot rules are marked when they were applied to a window, and removed once all windows that
// were created together have been checked.
//

void window_manager_remove_one_shot_rules(struct window_manager *wm)
{
    for (int i = 0; i < buf_len(wm->rules); ++i) {
        if (rule_check_flag(&wm->rules[i], RULE_ONE_SHOT_REMOVE)) {
            rule_destroy(&wm->rules[i]);
            if (buf_del(wm->rules, i)) --i;
        }
    }
}
