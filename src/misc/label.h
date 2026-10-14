#ifndef LABEL_H
#define LABEL_H

//
// NOTE: A label names a display or a space (id). A list holds each id and each name at most once;
// it owns the names.
//

struct label
{
    uint64_t id;
    char *label;
};

static inline struct label *label_find_id(struct label *list, uint64_t id)
{
    for (int i = 0; i < buf_len(list); ++i) {
        if (list[i].id == id) return &list[i];
    }

    return NULL;
}

static inline struct label *label_find_name(struct label *list, char *name)
{
    for (int i = 0; i < buf_len(list); ++i) {
        if (string_equals(list[i].label, name)) return &list[i];
    }

    return NULL;
}

static inline void label_remove_at(struct label **list, struct label *label)
{
    free(label->label);
    buf_del(*list, label - *list);
}

static inline bool label_remove_id(struct label **list, uint64_t id)
{
    struct label *label = label_find_id(*list, id);
    if (!label) return false;

    label_remove_at(list, label);
    return true;
}

//
// NOTE: Takes ownership of name. A name that labels another id moves to this id.
//

static inline void label_set(struct label **list, uint64_t id, char *name)
{
    label_remove_id(list, id);

    struct label *label = label_find_name(*list, name);
    if (label) label_remove_at(list, label);

    buf_push(*list, ((struct label) { .id = id, .label = name }));
}

#endif
