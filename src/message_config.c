//
// NOTE: The handler of the config domain. Options print their value when none is given.
//

static struct rgba_color *tab_bar_color_for_command(struct token command)
{
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_FOCUSED_COLOR))        return &g_window_manager.tab_bar_focused_color;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_FOCUSED_TEXT_COLOR))   return &g_window_manager.tab_bar_focused_text_color;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_INACTIVE_COLOR))       return &g_window_manager.tab_bar_inactive_color;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_INACTIVE_TEXT_COLOR))  return &g_window_manager.tab_bar_inactive_text_color;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_UNFOCUSED_COLOR))      return &g_window_manager.tab_bar_unfocused_color;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_UNFOCUSED_TEXT_COLOR)) return &g_window_manager.tab_bar_unfocused_text_color;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_BACKDROP_COLOR))       return &g_window_manager.tab_bar_backdrop_color;
    return NULL;
}

static bool *tab_bar_color_custom_for_command(struct token command)
{
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_FOCUSED_COLOR))   return &g_window_manager.tab_bar_focused_color_custom;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_INACTIVE_COLOR))  return &g_window_manager.tab_bar_inactive_color_custom;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_UNFOCUSED_COLOR)) return &g_window_manager.tab_bar_unfocused_color_custom;
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR_BACKDROP_COLOR))  return &g_window_manager.tab_bar_backdrop_color_custom;
    return NULL;
}

static void config_scratchpad_grid(FILE *rsp, struct token domain, struct token command, char **message)
{
    unsigned *grid = g_window_manager.scratchpad_grid;
    unsigned r, c, x, y, w, h;
    struct token value = get_token(message);

    if (!token_is_valid(value)) {
        if (grid[0] == 0 || grid[1] == 0) {
            fprintf(rsp, "%s\n", ARGUMENT_COMMON_VAL_OFF);
        } else {
            fprintf(rsp, "%u:%u:%u:%u:%u:%u\n", grid[0], grid[1], grid[2], grid[3], grid[4], grid[5]);
        }
    } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
        memset(grid, 0, sizeof(g_window_manager.scratchpad_grid));
    } else if ((sscanf(value.text, ARGUMENT_WINDOW_GRID, &r, &c, &x, &y, &w, &h) == 6) && r > 0 && c > 0) {
        grid[0] = r; grid[1] = c; grid[2] = x; grid[3] = y; grid[4] = w; grid[5] = h;
    } else {
        daemon_fail_unknown_value(rsp, domain, command, value);
    }
}

//
// NOTE: space_layout takes one layout per display count, e.g. '15 10:5 10:5:1b'. The layouts are the
// tokens that start with a digit, so the next command can follow them. Returns false when the message
// is invalid and the remaining commands must not be run.
//

static bool config_space_layout(FILE *rsp, struct token domain, struct token command, char **message, uint64_t sel_sid)
{
    if (sel_sid) {
        daemon_fail(rsp, "command '%.*s' for domain '%.*s' does not support the '%s' selector\n", command.length, command.text, domain.length, domain.text, SELECTOR_CONFIG_SPACE);
        return false;
    }

    char *cursor = *message;
    struct token value = get_token(message);

    if (!token_is_valid(value)) {
        fprintf(rsp, "%s\n", g_space_manager.space_layout_spec ? g_space_manager.space_layout_spec : ARGUMENT_COMMON_VAL_OFF);
        return true;
    }

    if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
        if (g_space_manager.space_layout_spec) free(g_space_manager.space_layout_spec);
        g_space_manager.space_layout_spec = NULL;
        g_space_manager.space_layout_count = 0;
        return true;
    }

    struct space_layout layout_list[SPACE_LAYOUT_MAX];
    int layout_count = 0;
    char spec[256] = {0};
    int spec_length = 0;

    while (token_is_valid(value) && value.text[0] >= '0' && value.text[0] <= '9') {
        if (layout_count == SPACE_LAYOUT_MAX || !space_manager_parse_space_layout(value.text, value.length, &layout_list[layout_count])) {
            daemon_fail(rsp, "invalid value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            return false;
        }

        for (int i = 0; i < layout_count; ++i) {
            if (layout_list[i].count == layout_list[layout_count].count) {
                daemon_fail(rsp, "value '%.*s' given to command '%.*s' for domain '%.*s' repeats a layout for %d display(s)\n", value.length, value.text, command.length, command.text, domain.length, domain.text, layout_list[i].count);
                return false;
            }
        }

        spec_length += snprintf(spec + spec_length, sizeof(spec) - spec_length, "%s%.*s", layout_count ? " " : "", value.length, value.text);
        if (spec_length >= (int) sizeof(spec)) {
            daemon_fail(rsp, "value given to command '%.*s' for domain '%.*s' is too long\n", command.length, command.text, domain.length, domain.text);
            return false;
        }

        ++layout_count;
        cursor = *message;
        value = get_token(message);
    }

    if (!layout_count) {
        daemon_fail_unknown_value(rsp, domain, command, value);
        return false;
    }

    *message = cursor;

    memcpy(g_space_manager.space_layout, layout_list, sizeof(struct space_layout) * layout_count);
    g_space_manager.space_layout_count = layout_count;
    if (g_space_manager.space_layout_spec) free(g_space_manager.space_layout_spec);
    g_space_manager.space_layout_spec = string_copy(spec);
    space_layout_schedule(0.0, true);
    return true;
}

//
// NOTE: Animations need the scripting addition and Screen Recording permission; 0 turns them off.
//

static void config_animation_duration(FILE *rsp, struct token domain, struct token command, char **message)
{
    struct token_value value = token_to_value(get_token(message));
    float duration;

    if (value.type == TOKEN_TYPE_INVALID) {
        fprintf(rsp, "%f\n", g_window_manager.window_animation_duration);
    } else if (!token_value_float(value, &duration)) {
        daemon_fail_unknown_value(rsp, domain, command, value.token);
    } else if (duration == 0.0f) {
        g_window_manager.window_animation_duration = duration;
    } else if (!scripting_addition_is_sip_friendly()) {
        daemon_fail(rsp, "command '%.*s' for domain '%.*s' requires System Integrity Protection to be partially disabled! ignoring request..\n", command.length, command.text, domain.length, domain.text);
    } else if (CGPreflightScreenCaptureAccess()) {
        g_window_manager.window_animation_duration = duration;
    } else {
        daemon_fail(rsp, "command '%.*s' for domain '%.*s' requires Screen Recording permissions! ignoring request..\n", command.length, command.text, domain.length, domain.text);
        CGRequestScreenCaptureAccess();
    }
}

static void config_layout(FILE *rsp, struct token domain, struct token command, char **message, uint64_t sel_sid)
{
    struct token value = get_token(message);

    if (!token_is_valid(value)) {
        enum view_type layout = sel_sid ? space_manager_find_view(&g_space_manager, sel_sid)->layout : g_space_manager.layout;
        fprintf(rsp, "%s\n", view_type_str[layout]);
        return;
    }

    enum view_type layout = token_equals(value, ARGUMENT_CONFIG_LAYOUT_FLOAT) ? VIEW_FLOAT
                          : token_equals(value, ARGUMENT_CONFIG_LAYOUT_TREE)  ? VIEW_TREE
                          : VIEW_DEFAULT;

    if (layout == VIEW_DEFAULT) {
        daemon_fail_unknown_value(rsp, domain, command, value);
    } else if (!sel_sid) {
        space_manager_set_layout_for_all_spaces(&g_space_manager, layout);
    } else if (!space_is_user(sel_sid)) {
        daemon_fail(rsp, "cannot set layout for a macOS fullscreen space!\n");
    } else {
        view_set_flag(space_manager_find_view(&g_space_manager, sel_sid), VIEW_LAYOUT);
        space_manager_set_layout_for_space(&g_space_manager, sel_sid, layout);
    }
}

static void config_external_bar(FILE *rsp, struct token domain, struct token command, char **message)
{
    int top, bottom;
    char mode[6];
    struct token value = get_token(message);

    if (sscanf(value.text, ARGUMENT_CONFIG_EXTERNAL_BAR, mode, &top, &bottom) != 3) {
        fprintf(rsp, "%s:%d:%d\n", external_bar_mode_str[g_display_manager.mode], g_display_manager.top_padding, g_display_manager.bottom_padding);
        return;
    }

    for (int i = 0; i < array_count(external_bar_mode_str); ++i) {
        if (string_equals(mode, external_bar_mode_str[i])) {
            g_display_manager.mode = i;
            g_display_manager.top_padding = top;
            g_display_manager.bottom_padding = bottom;
            space_manager_mark_spaces_invalid(&g_space_manager);
            return;
        }
    }

    daemon_fail(rsp, "unknown mode '%s' specified in value '%.*s' given to command '%.*s' for domain '%.*s'\n", mode, value.length, value.text, command.length, command.text, domain.length, domain.text);
}

static enum view_flag spacing_for_command(struct token command)
{
    if (token_equals(command, COMMAND_CONFIG_TOP_PADDING))    return VIEW_TOP_PADDING;
    if (token_equals(command, COMMAND_CONFIG_BOTTOM_PADDING)) return VIEW_BOTTOM_PADDING;
    if (token_equals(command, COMMAND_CONFIG_LEFT_PADDING))   return VIEW_LEFT_PADDING;
    if (token_equals(command, COMMAND_CONFIG_RIGHT_PADDING))  return VIEW_RIGHT_PADDING;
    if (token_equals(command, COMMAND_CONFIG_WINDOW_GAP))     return VIEW_WINDOW_GAP;
    return 0;
}

//
// NOTE: The window_border options. Returns false when command is not one of them.
//

static bool config_border(FILE *rsp, struct token domain, struct token command, char **message)
{
    if (token_equals(command, COMMAND_CONFIG_BORDER)) {
        if (parse_config_bool(rsp, domain, command, message, &g_window_manager.enable_window_border)) border_refresh_all();
    } else if (token_equals(command, COMMAND_CONFIG_BORDER_HIDE_SINGLE)) {
        if (parse_config_bool(rsp, domain, command, message, &g_window_manager.window_border_hide_single)) border_refresh_all();
    } else if (token_equals(command, COMMAND_CONFIG_BORDER_WIDTH)) {
        struct token_value value = token_to_value(get_token(message));
        float width;
        if (value.type == TOKEN_TYPE_INVALID) {
            fprintf(rsp, "%.4f\n", g_window_manager.window_border_width);
        } else if (token_value_float(value, &width) && width > 0.0f) {
            g_window_manager.window_border_width = width;
            border_refresh_all();
        } else {
            daemon_fail_unknown_value(rsp, domain, command, value.token);
        }
    } else if (token_equals(command, COMMAND_CONFIG_ACTIVE_BORDER_COLOR) || token_equals(command, COMMAND_CONFIG_NORMAL_BORDER_COLOR)) {
        struct rgba_color *color = token_equals(command, COMMAND_CONFIG_ACTIVE_BORDER_COLOR)
                                 ? &g_window_manager.active_window_border_color
                                 : &g_window_manager.normal_window_border_color;
        struct token_value value = token_to_value(get_token(message));
        if (value.type == TOKEN_TYPE_INVALID) {
            fprintf(rsp, "0x%x\n", color->p);
        } else if (value.type == TOKEN_TYPE_U32) {
            *color = rgba_color_from_hex(value.u32_value);
            border_refresh_all();
        } else {
            daemon_fail_unknown_value(rsp, domain, command, value.token);
        }
    } else {
        return false;
    }

    return true;
}

//
// NOTE: The tab_bar options. Returns false when command is not one of them.
//

static bool config_tab_bar(FILE *rsp, struct token domain, struct token command, char **message)
{
    if (token_equals(command, COMMAND_CONFIG_TAB_BAR)) {
        if (parse_config_bool(rsp, domain, command, message, &g_window_manager.enable_tab_bar)) tab_bar_refresh_all();
    } else if (token_equals(command, COMMAND_CONFIG_TAB_BAR_HEIGHT)) {
        struct token_value value = token_to_value(get_token(message));
        if (value.type == TOKEN_TYPE_INVALID) {
            fprintf(rsp, "%d\n", g_window_manager.tab_bar_height);
        } else if (value.type == TOKEN_TYPE_INT && value.int_value > 0) {
            g_window_manager.tab_bar_height = value.int_value;
            tab_bar_refresh_all();
        } else {
            daemon_fail_unknown_value(rsp, domain, command, value.token);
        }
    } else if (token_equals(command, COMMAND_CONFIG_TAB_BAR_OFFSET)) {
        struct token_value value = token_to_value(get_token(message));
        if (value.type == TOKEN_TYPE_INVALID) {
            fprintf(rsp, "%d\n", g_window_manager.tab_bar_offset);
        } else if (value.type == TOKEN_TYPE_INT) {
            g_window_manager.tab_bar_offset = value.int_value;
            tab_bar_refresh_all();
        } else if (value.type == TOKEN_TYPE_FLOAT && value.float_value == (int) value.float_value) {
            g_window_manager.tab_bar_offset = (int) value.float_value;
            tab_bar_refresh_all();
        } else {
            daemon_fail_unknown_value(rsp, domain, command, value.token);
        }
    } else if (token_equals(command, COMMAND_CONFIG_TAB_BAR_ICONS)) {
        if (parse_config_bool(rsp, domain, command, message, &g_window_manager.tab_bar_icons)) tab_bar_redraw_all();
    } else if (token_equals(command, COMMAND_CONFIG_TAB_BAR_STYLE)) {
        struct token value = get_token(message);
        enum tab_bar_style style;
        if (!token_is_valid(value)) {
            fprintf(rsp, "%s\n", tab_bar_style_str[g_window_manager.tab_bar_style]);
        } else if (tab_bar_parse_style(value.text, &style)) {
            g_window_manager.tab_bar_style = style;
            tab_bar_refresh_all();
        } else {
            daemon_fail_unknown_value(rsp, domain, command, value);
        }
    } else if (token_equals(command, COMMAND_CONFIG_TAB_BAR_BACKDROP)) {
        struct token value = get_token(message);
        enum tab_bar_backdrop backdrop;
        if (!token_is_valid(value)) {
            fprintf(rsp, "%s\n", tab_bar_backdrop_str[g_window_manager.tab_bar_backdrop]);
        } else if (tab_bar_parse_backdrop(value.text, &backdrop)) {
            g_window_manager.tab_bar_backdrop = backdrop;
            tab_bar_refresh_all();
        } else {
            daemon_fail_unknown_value(rsp, domain, command, value);
        }
    } else if (token_equals(command, COMMAND_CONFIG_TAB_BAR_CARD_PADDING)) {
        struct token_value value = token_to_value(get_token(message));
        if (value.type == TOKEN_TYPE_INVALID) {
            fprintf(rsp, "%d\n", g_window_manager.tab_bar_card_padding);
        } else if (value.type == TOKEN_TYPE_INT && value.int_value >= 0) {
            g_window_manager.tab_bar_card_padding = value.int_value;
            tab_bar_refresh_all();
        } else {
            daemon_fail_unknown_value(rsp, domain, command, value.token);
        }
    } else if (token_equals(command, COMMAND_CONFIG_TAB_BAR_WINDOW_RADIUS)) {
        struct token_value value = token_to_value(get_token(message));
        if (value.type == TOKEN_TYPE_INVALID) {
            fprintf(rsp, "%d\n", g_window_manager.tab_bar_window_radius);
        } else if (value.type == TOKEN_TYPE_INT && value.int_value >= 0) {
            g_window_manager.tab_bar_window_radius = value.int_value;
            tab_bar_redraw_all();
        } else {
            daemon_fail_unknown_value(rsp, domain, command, value.token);
        }
    } else if (token_equals(command, COMMAND_CONFIG_TAB_BAR_FONT)) {
        struct token value = get_token(message);
        if (!token_is_valid(value)) {
            fprintf(rsp, "%s\n", g_window_manager.tab_bar_font_name ? g_window_manager.tab_bar_font_name : "");
        } else if (tab_bar_set_font(value.text)) {
            tab_bar_redraw_all();
        } else {
            daemon_fail_unknown_value(rsp, domain, command, value);
        }
    } else if (tab_bar_color_for_command(command)) {
        struct rgba_color *color = tab_bar_color_for_command(command);
        struct token_value value = token_to_value(get_token(message));
        if (value.type == TOKEN_TYPE_INVALID) {
            fprintf(rsp, "0x%x\n", color->p);
        } else if (value.type == TOKEN_TYPE_U32) {
            *color = rgba_color_from_hex(value.u32_value);
            bool *custom = tab_bar_color_custom_for_command(command);
            if (custom) *custom = true;
            tab_bar_redraw_all();
        } else {
            daemon_fail_unknown_value(rsp, domain, command, value.token);
        }
    } else {
        return false;
    }

    return true;
}

static void handle_domain_config(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    uint64_t sel_sid = 0;
    struct token selector = get_token(&message);
    struct token command  = selector;

    bool found_selector = token_equals(selector, SELECTOR_CONFIG_SPACE);
    if (found_selector) {
        struct selector space_selector = parse_space_selector(rsp, &message, 0, false);
        if (!space_selector.did_parse || !space_selector.sid) return;

        sel_sid = space_selector.sid;
        command = get_token(&message);
    }

    for (; token_is_valid(command); command = get_token(&message)) {
        if (config_border(rsp, domain, command, &message))  continue;
        if (config_tab_bar(rsp, domain, command, &message)) continue;

        if (token_equals(command, COMMAND_CONFIG_DEBUG_OUTPUT)) {
            parse_config_bool(rsp, domain, command, &message, &g_verbose);
        } else if (token_equals(command, COMMAND_CONFIG_MFF)) {
            parse_config_bool(rsp, domain, command, &message, &g_window_manager.enable_mff);
        } else if (token_equals(command, COMMAND_CONFIG_FFM)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", ffm_mode_str[g_window_manager.ffm_mode]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                window_manager_set_focus_follows_mouse(&g_window_manager, FFM_DISABLED);
            } else if (token_equals(value, ARGUMENT_CONFIG_FFM_AUTOFOCUS)) {
                window_manager_set_focus_follows_mouse(&g_window_manager, FFM_AUTOFOCUS);
            } else if (token_equals(value, ARGUMENT_CONFIG_FFM_AUTORAISE)) {
                window_manager_set_focus_follows_mouse(&g_window_manager, FFM_AUTORAISE);
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_CONFIG_DISPLAY_ORDER)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, display_arrangement_order_str, DISPLAY_ARRANGEMENT_ORDER_DEFAULT, DISPLAY_ARRANGEMENT_ORDER_Y, g_display_manager.order, &choice)) g_display_manager.order = choice;
        } else if (token_equals(command, COMMAND_CONFIG_BUILTIN_LAST)) {
            if (parse_config_bool(rsp, domain, command, &message, &g_display_manager.builtin_last)) space_layout_schedule(0.0, true);
        } else if (token_equals(command, COMMAND_CONFIG_WINDOW_ORIGIN)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, window_origin_mode_str, WINDOW_ORIGIN_DEFAULT, WINDOW_ORIGIN_CURSOR, g_window_manager.window_origin_mode, &choice)) g_window_manager.window_origin_mode = choice;
        } else if (token_equals(command, COMMAND_CONFIG_SCRATCHPAD_EXCLUSIVE)) {
            parse_config_bool(rsp, domain, command, &message, &g_window_manager.scratchpad_exclusive);
        } else if (token_equals(command, COMMAND_CONFIG_SCRATCHPAD_RAISE)) {
            parse_config_bool(rsp, domain, command, &message, &g_window_manager.scratchpad_raise);
        } else if (token_equals(command, COMMAND_CONFIG_SCRATCHPAD_BELOW)) {
            if (parse_config_bool(rsp, domain, command, &message, &g_window_manager.scratchpad_below)) window_manager_set_scratchpad_layers(&g_window_manager);
        } else if (token_equals(command, COMMAND_CONFIG_SCRATCHPAD_GRID)) {
            config_scratchpad_grid(rsp, domain, command, &message);
        } else if (token_equals(command, COMMAND_CONFIG_SKIP_SPACE_ANIMATION)) {
            parse_config_bool(rsp, domain, command, &message, &g_space_manager.skip_window_focus_animation);
        } else if (token_equals(command, COMMAND_CONFIG_SPACE_LAYOUT)) {
            if (!config_space_layout(rsp, domain, command, &message, sel_sid)) return;
        } else if (token_equals(command, COMMAND_CONFIG_OPACITY)) {
            bool enabled = g_window_manager.enable_window_opacity;
            if (parse_config_bool(rsp, domain, command, &message, &enabled)) window_manager_set_window_opacity_enabled(&g_window_manager, enabled);
        } else if (token_equals(command, COMMAND_CONFIG_OPACITY_DURATION)) {
            struct token_value value = token_to_value(get_token(&message));
            float duration;
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%f\n", g_window_manager.window_opacity_duration);
            } else if (token_value_float(value, &duration)) {
                g_window_manager.window_opacity_duration = duration;
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (token_equals(command, COMMAND_CONFIG_ANIMATION_DURATION)) {
            config_animation_duration(rsp, domain, command, &message);
        } else if (token_equals(command, COMMAND_CONFIG_ANIMATION_EASING)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, animation_easing_type_str, 0, EASING_TYPE_COUNT-1, g_window_manager.window_animation_easing, &choice)) g_window_manager.window_animation_easing = choice;
        } else if (token_equals(command, COMMAND_CONFIG_SHADOW)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, purify_mode_str, PURIFY_DISABLED, PURIFY_ALWAYS, g_window_manager.purify_mode, &choice)) window_manager_set_purify_mode(&g_window_manager, choice);
        } else if (token_equals(command, COMMAND_CONFIG_MENUBAR_OPACITY)) {
            struct token_value value = token_to_value(get_token(&message));
            float opacity;
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%.4f\n", g_window_manager.menubar_opacity);
            } else if (token_value_float(value, &opacity) && in_range_ii(opacity, 0.0f, 1.0f)) {
                window_manager_set_menubar_opacity(&g_window_manager, opacity);
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (token_equals(command, COMMAND_CONFIG_ACTIVE_WINDOW_OPACITY)) {
            struct token_value value = token_to_value(get_token(&message));
            float opacity;
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%.4f\n", g_window_manager.active_window_opacity);
            } else if (token_value_float(value, &opacity) && in_range_ei(opacity, 0.0f, 1.0f)) {
                window_manager_set_active_window_opacity(&g_window_manager, opacity);
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (token_equals(command, COMMAND_CONFIG_NORMAL_WINDOW_OPACITY)) {
            struct token_value value = token_to_value(get_token(&message));
            float opacity;
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%.4f\n", g_window_manager.normal_window_opacity);
            } else if (token_value_float(value, &opacity) && in_range_ei(opacity, 0.0f, 1.0f)) {
                window_manager_set_normal_window_opacity(&g_window_manager, opacity);
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (token_equals(command, COMMAND_CONFIG_INSERT_FEEDBACK_COLOR)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "0x%x\n", g_window_manager.insert_feedback_color.p);
            } else if (value.type == TOKEN_TYPE_U32 && value.u32_value) {
                g_window_manager.insert_feedback_color = rgba_color_from_hex(value.u32_value);
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            }
        } else if (spacing_for_command(command)) {
            enum view_flag flag = spacing_for_command(command);
            struct view *view = sel_sid ? space_manager_find_view(&g_space_manager, sel_sid) : NULL;
            int *spacing = view ? view_spacing(view, flag) : space_manager_spacing(&g_space_manager, flag);
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%d\n", *spacing);
            } else if (value.type != TOKEN_TYPE_INT) {
                daemon_fail_unknown_value(rsp, domain, command, value.token);
            } else if (view) {
                view_set_flag(view, flag);
                *spacing = value.int_value;
                view_update_and_flush(view);
            } else {
                space_manager_set_spacing_for_all_spaces(&g_space_manager, flag, value.int_value);
            }
        } else if (token_equals(command, COMMAND_CONFIG_LAYOUT)) {
            config_layout(rsp, domain, command, &message, sel_sid);
        } else if (token_equals(command, COMMAND_CONFIG_TREE_ORIENTATION)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, tree_orientation_str, TREE_ORIENTATION_AUTO, TREE_ORIENTATION_VERTICAL, g_space_manager.tree_default_orientation, &choice)) g_space_manager.tree_default_orientation = choice;
        } else if (token_equals(command, COMMAND_CONFIG_TREE_WORKSPACE_LAYOUT)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", g_space_manager.tree_workspace_tabbed ? ARGUMENT_CONFIG_TREE_TABBED : ARGUMENT_CONFIG_TREE_DEFAULT);
            } else if (token_equals(value, ARGUMENT_CONFIG_TREE_DEFAULT)) {
                g_space_manager.tree_workspace_tabbed = false;
            } else if (token_equals(value, ARGUMENT_CONFIG_TREE_TABBED)) {
                g_space_manager.tree_workspace_tabbed = true;
            } else {
                daemon_fail_unknown_value(rsp, domain, command, value);
            }
        } else if (token_equals(command, COMMAND_CONFIG_TREE_AUTOTILING)) {
            parse_config_bool(rsp, domain, command, &message, &g_space_manager.tree_autotiling);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_WRAPPING)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, focus_wrapping_str, FOCUS_WRAPPING_OFF, FOCUS_WRAPPING_FORCE, g_window_manager.focus_wrapping, &choice)) g_window_manager.focus_wrapping = choice;
        } else if (token_equals(command, COMMAND_CONFIG_AUTO_PADDING)) {
            if (sel_sid) {
                bool enabled = space_manager_find_view(&g_space_manager, sel_sid)->auto_padding;
                if (parse_config_bool(rsp, domain, command, &message, &enabled)) space_manager_set_auto_padding_for_space(&g_space_manager, sel_sid, enabled);
            } else {
                bool enabled = g_space_manager.auto_padding;
                if (parse_config_bool(rsp, domain, command, &message, &enabled)) space_manager_set_auto_padding_for_all_spaces(&g_space_manager, enabled);
            }
        } else if (token_equals(command, COMMAND_CONFIG_MOUSE_MOD)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, mouse_mod_str, MOUSE_MOD_ALT, MOUSE_MOD_FN, g_mouse_state.modifier, &choice)) g_mouse_state.modifier = choice;
        } else if (token_equals(command, COMMAND_CONFIG_MOUSE_ACTION1)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, mouse_mode_str, MOUSE_MODE_MOVE, MOUSE_MODE_RESIZE, g_mouse_state.action1, &choice)) g_mouse_state.action1 = choice;
        } else if (token_equals(command, COMMAND_CONFIG_MOUSE_ACTION2)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, mouse_mode_str, MOUSE_MODE_MOVE, MOUSE_MODE_RESIZE, g_mouse_state.action2, &choice)) g_mouse_state.action2 = choice;
        } else if (token_equals(command, COMMAND_CONFIG_MOUSE_DROP_ACTION)) {
            int choice;
            if (parse_config_choice(rsp, domain, command, &message, mouse_mode_str, MOUSE_MODE_SWAP, MOUSE_MODE_STACK, g_mouse_state.drop_action, &choice)) g_mouse_state.drop_action = choice;
        } else if (token_equals(command, COMMAND_CONFIG_EXTERNAL_BAR)) {
            config_external_bar(rsp, domain, command, &message);
        } else {
            daemon_fail_unknown_command(rsp, domain, command);
        }
    }
}

