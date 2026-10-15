#ifndef SA_H
#define SA_H

extern unsigned char __src_osax_payload[];
extern unsigned int __src_osax_payload_len;
extern unsigned char __src_osax_loader[];
extern unsigned int __src_osax_loader_len;

extern int csr_get_active_config(uint32_t *config);
extern char g_sa_socket_file[MAXLEN];
static inline char *sa_socket_path(void) { return g_sa_socket_file; }
static inline unsigned char *sa_loader_bytes(void) { return __src_osax_loader; }
static inline unsigned int sa_loader_size(void) { return __src_osax_loader_len; }
static inline unsigned char *sa_payload_bytes(void) { return __src_osax_payload; }
static inline unsigned int sa_payload_size(void) { return __src_osax_payload_len; }

// Swift cannot call the variadic notification function.
#ifdef __swift__
void sa_notify(const char *text);
#else
void sa_notify(const char *text) { notify("scripting-addition", "%s", text); }
#endif

struct sa_window_order
{
    uint32_t a_wid;
    int order;
    uint32_t b_wid;
};

int scripting_addition_load(void);
void scripting_addition_payload_changed(void);
int scripting_addition_uninstall(void);

#endif
