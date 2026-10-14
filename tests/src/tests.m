unsigned char __src_osax_payload[1];
unsigned int __src_osax_payload_len;
unsigned char __src_osax_loader[1];
unsigned int __src_osax_loader_len;

#include "../../src/manifest.m"

#define TEST_SIG(name) bool test_##name(void)
typedef TEST_SIG(function);

#define TEST_FUNC(name, code) static TEST_SIG(name) { char *test_name = #name; bool result = true; {code} return result; }
#define TEST_CHECK(r, e) if ((r) != (e)) { printf("                   \e[1;33m%s\e[m\e[1;31m#%d %s == %s\e[m \e[1;31m(%d == %d)\e[m\n", test_name, __LINE__, #r, #e, r, e); result = false; }

#include "area.c"
#include "space_layout.c"
#include "auto_padding.c"
#include "tree.c"
#include "tree_view.c"
#include "tab_bar.c"
#include "window_frame.c"
#include "border.c"
#include "message.c"
#include "window_info.c"
#include "window_rules.c"
#include "space_window.c"
#include "label.c"
#include "event_signal.c"

#define TEST_ENTRY(name) { #name, test_##name },
#define TEST_LIST                                              \
    TEST_ENTRY(display_area_is_in_direction)                   \
    TEST_ENTRY(closest_display_in_direction)                   \
    TEST_ENTRY(space_layout_parse)                             \
    TEST_ENTRY(space_layout_targets)                           \
    TEST_ENTRY(space_move_replacement)                         \
    TEST_ENTRY(space_layout_move_candidate)                    \
    TEST_ENTRY(space_list_navigation)                          \
    TEST_ENTRY(auto_padding_applies)                           \
    TEST_ENTRY(auto_padding_tiled_count)                \
    TEST_ENTRY(auto_padding_root_area)                         \
    TEST_ENTRY(auto_padding_gap)                               \
    TEST_ENTRY(auto_padding_split_in_tab)                      \
    TEST_ENTRY(tree_attach_detach)                             \
    TEST_ENTRY(tree_flatten)                                   \
    TEST_ENTRY(tree_focus_direction)                           \
    TEST_ENTRY(tree_focus_tabbed)                              \
    TEST_ENTRY(tree_move_within)                               \
    TEST_ENTRY(tree_move_force_orientation)                    \
    TEST_ENTRY(tree_move_tabbed)                               \
    TEST_ENTRY(tree_split_layout)                              \
    TEST_ENTRY(tree_insert_relative)                           \
    TEST_ENTRY(tree_resize_update)                             \
    TEST_ENTRY(tree_rotate_mirror_swap)                        \
    TEST_ENTRY(tree_focus_candidate)                           \
    TEST_ENTRY(tree_flatten_same_orientation)                  \
    TEST_ENTRY(tree_autotiling)                                \
    TEST_ENTRY(tree_set_layout_single_tab)                     \
    TEST_ENTRY(tree_workspace_layout_tabbed)                   \
    TEST_ENTRY(tree_insert_focus_order)                        \
    TEST_ENTRY(tree_open_con_selected)                         \
    TEST_ENTRY(tree_attach_from_direction)                     \
    TEST_ENTRY(tree_window_order_collect)                      \
    TEST_ENTRY(tree_window_ids_collect)                        \
    TEST_ENTRY(tree_view_window_list_order)                    \
    TEST_ENTRY(tree_view_zoom_frames)                          \
    TEST_ENTRY(tree_view_serialize_tree)                       \
    TEST_ENTRY(tab_bar_style_parse)                            \
    TEST_ENTRY(tab_bar_backdrop_parse)                         \
    TEST_ENTRY(tab_bar_font_parse)                             \
    TEST_ENTRY(tab_bar_glass_tint_default)                     \
    TEST_ENTRY(tab_bar_title_fits)                             \
    TEST_ENTRY(window_frame_close)                             \
    TEST_ENTRY(window_frame_group_by_application)              \
    TEST_ENTRY(window_frame_needs_update_decision)             \
    TEST_ENTRY(window_pending_focus)                           \
    TEST_ENTRY(window_unresolved_list)                         \
    TEST_ENTRY(window_validity)                                \
    TEST_ENTRY(window_one_shot_rules)                          \
    TEST_ENTRY(space_known_focus)                              \
    TEST_ENTRY(space_window_user_predicates)                   \
    TEST_ENTRY(label_list)                                     \
    TEST_ENTRY(application_launch_retry_backoff)               \
    TEST_ENTRY(mouse_event_coalescing)                         \
    TEST_ENTRY(mouse_resize_handle)                            \
    TEST_ENTRY(mouse_drop_action_regions)                      \
    TEST_ENTRY(border_edge_frames_split)                       \
    TEST_ENTRY(border_tabbed_container_area)                   \
    TEST_ENTRY(message_config_bool)                            \
    TEST_ENTRY(message_config_choice)                          \
    TEST_ENTRY(message_config_options)                         \
    TEST_ENTRY(message_config_values)                          \
    TEST_ENTRY(message_window_toggle_lookup)                   \
    TEST_ENTRY(message_window_layout_values)                   \
    TEST_ENTRY(message_window_command_groups)                  \
    TEST_ENTRY(message_space_command_groups)                   \
    TEST_ENTRY(message_label_reserved)                         \
    TEST_ENTRY(message_rule_parse)                             \
    TEST_ENTRY(message_client_encoding)                        \
    TEST_ENTRY(message_selectors)                              \
    TEST_ENTRY(message_query_target)                           \
    TEST_ENTRY(message_signal_parse)                           \
    TEST_ENTRY(json_string_escaping)                           \
    TEST_ENTRY(rule_effects_combine)                           \
    TEST_ENTRY(window_rules_combine_matching)                  \
    TEST_ENTRY(window_rules_manage_round)                      \
    TEST_ENTRY(window_info_serialize_selected)                 \
    TEST_ENTRY(window_info_tree_fields)                        \
    TEST_ENTRY(event_signal_filter_properties)                 \
    TEST_ENTRY(event_signal_args)                              \
    TEST_ENTRY(event_signal_describe_spaces)

static struct {
    char *name;
    test_function *func;
} tests[] = {
    TEST_LIST
};

int main(void)
{
    int succeeded = 0;
    int failed = 0;
    int total = array_count(tests);
    if (!ts_init(MEGABYTES(1))) return EXIT_FAILURE;

    printf("\e[1;34m -- Running %d tests\e[m\n\n", total);

    uint64_t cpu_freq  = read_cpu_freq();
    uint64_t begin_tsc = read_cpu_timer();

    for (int i = 0; i < total; ++i) {
        uint64_t tsc = read_cpu_timer();
        bool result = tests[i].func();
        double ms_elapsed = 1000.0 * (double)(read_cpu_timer() - tsc) / (double)cpu_freq;

        printf("(%0.4fms) %s \e[1;33m%s\e[m\n", ms_elapsed, result ? "\e[1;32msuccess\e[m" : " \e[1;31mfailed\e[m", tests[i].name);
        if (result) ++succeeded; else ++failed;
    }

    double ms_elapsed = 1000.0 * (double)(read_cpu_timer() - begin_tsc) / (double)cpu_freq;
    printf("\n\e[1;34m -- Completed (%0.4fms)\e[m\n", ms_elapsed);
    printf("\t%d \e[1;32msucceeded\e[m\n", succeeded);
    printf("\t%d \e[1;31mfailed\e[m\n", failed);
    printf("\t%d \e[1;33mtotal\e[m\n", total);

    return total == succeeded ? EXIT_SUCCESS : EXIT_FAILURE;
}
