#ifndef LABEL_H
#define LABEL_H

//
// NOTE: A label names a display or a space (id). A list holds each id and each name at most once.
// The lists are Swift (LabelList in Sources/YabaiCore/Label.swift); these functions are implemented in
// Sources/Yabai/Shims/LabelShims.swift. C holds a list as an opaque reference: NULL is an empty list, the first
// label_set creates it, and nothing frees it, because the managers own their lists while the daemon runs.
//

struct label_list;

// the name of id in temporary storage, or NULL
char *label_find_id(struct label_list *list, uint64_t id);
bool label_find_name(struct label_list *list, char *name, uint64_t *id);
bool label_remove_id(struct label_list *list, uint64_t id);

//
// NOTE: Takes ownership of name. A name that labels another id moves to this id.
//

void label_set(struct label_list **list, uint64_t id, char *name);

// the label of id, if any, moves to new_id
void label_replace_id(struct label_list *list, uint64_t id, uint64_t new_id);
// the labels of a and b trade places
void label_swap_ids(struct label_list *list, uint64_t a, uint64_t b);

#endif
