/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Cyppe
 *
 * omarchy_autosuggest.c - tiny history autosuggestions for Bash/Readline.
 *
 * This is a Bash loadable builtin, not a replacement line editor. It keeps a
 * history match in Readline's active region, removes it before normal editing,
 * and lets forward-char/forward-word/end-of-line accept the suggestion.
 *
 * There is no daemon, database, network access, or per-key subprocess.
 */

#include <errno.h>
#include <limits.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#include <bash/builtins.h>
#include <bash/shell.h>
#include <readline/history.h>
#include <readline/keymaps.h>
#include <readline/readline.h>

#ifndef OMARCHY_AUTOSUGGEST_VERSION
#define OMARCHY_AUTOSUGGEST_VERSION "development"
#endif

typedef struct {
  Keymap map;
  int key;
  rl_command_func_t *original;
} saved_binding;

static saved_binding *bindings;
static size_t bindings_len;
static size_t bindings_cap;

static Keymap *visited_maps;
static size_t visited_len;
static size_t visited_cap;

static int plugin_enabled;
static int suggestion_active;
static int suggestion_start;
static int saved_mark;
static int saved_mark_active;
static int style_active;
static int history_navigation_active;
static int history_scan_limit = 8192;

static char *old_region_start;
static char *old_region_end;
static char *old_region_enabled;
static char *dismissed_line;
static char *history_navigation_line;

static rl_command_func_t *last_original;

static rl_command_func_t *fn_abort;
static rl_command_func_t *fn_beginning_of_history;
static rl_command_func_t *fn_digit_argument;
static rl_command_func_t *fn_end_of_history;
static rl_command_func_t *fn_forward_char;
static rl_command_func_t *fn_forward_word;
static rl_command_func_t *fn_history_search_backward;
static rl_command_func_t *fn_history_search_forward;
static rl_command_func_t *fn_history_substring_search_backward;
static rl_command_func_t *fn_history_substring_search_forward;
static rl_command_func_t *fn_next_history;
static rl_command_func_t *fn_previous_history;
static rl_command_func_t *fn_shell_forward_word;
static rl_command_func_t *fn_end_of_line;
static rl_command_func_t *fn_vi_arg_digit;

static int autosuggest_dispatch(int count, int key);

static char *copy_string(const char *value) {
  size_t length;
  char *copy;

  if (value == NULL)
    return NULL;
  length = strlen(value) + 1;
  copy = malloc(length);
  if (copy != NULL)
    memcpy(copy, value, length);
  return copy;
}

static int grow_array(void **array, size_t *capacity, size_t item_size) {
  size_t new_capacity = *capacity == 0 ? 64 : *capacity * 2;
  void *new_array;

  if (new_capacity < *capacity || new_capacity > SIZE_MAX / item_size)
    return 0;
  new_array = realloc(*array, new_capacity * item_size);
  if (new_array == NULL)
    return 0;
  *array = new_array;
  *capacity = new_capacity;
  return 1;
}

static int remember_binding(Keymap map, int key, rl_command_func_t *original) {
  if (bindings_len == bindings_cap &&
      !grow_array((void **)&bindings, &bindings_cap, sizeof(*bindings)))
    return 0;
  bindings[bindings_len++] = (saved_binding){map, key, original};
  return 1;
}

static int map_was_visited(Keymap map) {
  size_t i;

  for (i = 0; i < visited_len; ++i)
    if (visited_maps[i] == map)
      return 1;
  return 0;
}

static int remember_map(Keymap map) {
  if (visited_len == visited_cap &&
      !grow_array((void **)&visited_maps, &visited_cap,
                  sizeof(*visited_maps)))
    return 0;
  visited_maps[visited_len++] = map;
  return 1;
}

static int wrap_keymap(Keymap map) {
  int key;

  if (map == NULL || map_was_visited(map))
    return 1;
  if (!remember_map(map))
    return 0;

  for (key = 0; key < KEYMAP_SIZE; ++key) {
    KEYMAP_ENTRY *entry = &map[key];

    if (entry->type == ISKMAP) {
      if (!wrap_keymap((Keymap)entry->function))
        return 0;
    } else if (entry->type == ISFUNC && entry->function != NULL &&
               entry->function != autosuggest_dispatch) {
      if (!remember_binding(map, key, entry->function))
        return 0;
      entry->function = autosuggest_dispatch;
    }
  }
  return 1;
}

static rl_command_func_t *find_original(Keymap map, int key) {
  size_t i;

  for (i = bindings_len; i > 0; --i) {
    saved_binding *binding = &bindings[i - 1];
    if (binding->map == map && binding->key == key)
      return binding->original;
  }
  return NULL;
}

static void restore_keymaps(void) {
  size_t i;

  for (i = bindings_len; i > 0; --i) {
    saved_binding *binding = &bindings[i - 1];
    KEYMAP_ENTRY *entry = &binding->map[binding->key];
    if (entry->type == ISFUNC && entry->function == autosuggest_dispatch)
      entry->function = binding->original;
  }
  free(bindings);
  bindings = NULL;
  bindings_len = 0;
  bindings_cap = 0;
  free(visited_maps);
  visited_maps = NULL;
  visited_len = 0;
  visited_cap = 0;
}

static void save_region_style(void) {
  old_region_start = copy_string(rl_variable_value("active-region-start-color"));
  old_region_end = copy_string(rl_variable_value("active-region-end-color"));
  old_region_enabled = copy_string(rl_variable_value("enable-active-region"));
}

static void use_suggestion_style(void) {
  if (style_active)
    return;
  rl_variable_bind("enable-active-region", "on");
  rl_variable_bind("active-region-start-color", "\033[2;3m");
  rl_variable_bind("active-region-end-color", "\033[22;23m");
  style_active = 1;
}

static void restore_region_style(void) {
  if (!style_active)
    return;
  if (old_region_enabled != NULL)
    rl_variable_bind("enable-active-region", old_region_enabled);
  if (old_region_start != NULL)
    rl_variable_bind("active-region-start-color", old_region_start);
  if (old_region_end != NULL)
    rl_variable_bind("active-region-end-color", old_region_end);
  style_active = 0;
}

static void free_region_style(void) {
  restore_region_style();
  free(old_region_start);
  free(old_region_end);
  free(old_region_enabled);
  old_region_start = NULL;
  old_region_end = NULL;
  old_region_enabled = NULL;
}

static void clear_dismissed_line(void) {
  free(dismissed_line);
  dismissed_line = NULL;
}

static void dismiss_current_line(void) {
  clear_dismissed_line();
  dismissed_line = copy_string(rl_line_buffer);
}

static int current_line_is_dismissed(void) {
  if (dismissed_line == NULL || rl_line_buffer == NULL)
    return 0;
  if (strcmp(dismissed_line, rl_line_buffer) == 0)
    return 1;
  clear_dismissed_line();
  return 0;
}

static void clear_history_navigation(void) {
  history_navigation_active = 0;
  free(history_navigation_line);
  history_navigation_line = NULL;
}

static void remember_history_navigation(void) {
  clear_history_navigation();
  history_navigation_line = copy_string(rl_line_buffer);
  history_navigation_active = 1;
}

static void finish_non_history_command(void) {
  if (!history_navigation_active)
    return;
  if (history_navigation_line == NULL || rl_line_buffer == NULL ||
      strcmp(history_navigation_line, rl_line_buffer) != 0)
    clear_history_navigation();
}

static void strip_suggestion(void) {
  int typed_length;

  if (!suggestion_active)
    return;

  typed_length = suggestion_start;
  if (typed_length < 0 || typed_length > rl_end)
    typed_length = rl_point < rl_end ? rl_point : rl_end;

  rl_line_buffer[typed_length] = '\0';
  rl_end = typed_length;
  rl_point = typed_length;
  rl_mark = saved_mark <= typed_length ? saved_mark : typed_length;
  if (saved_mark_active)
    rl_activate_mark();
  else
    rl_deactivate_mark();
  suggestion_active = 0;
}

static const char *find_history_match(const char *prefix, size_t prefix_length) {
  HIST_ENTRY **entries;
  int first;
  int i;

  if (prefix_length == 0 || history_length <= 0)
    return NULL;
  entries = history_list();
  if (entries == NULL)
    return NULL;

  first = history_length - history_scan_limit;
  if (first < 0)
    first = 0;

  for (i = history_length - 1; i >= first; --i) {
    const char *line = entries[i] == NULL ? NULL : entries[i]->line;
    if (line == NULL || strchr(line, '\n') != NULL ||
        strchr(line, '\r') != NULL)
      continue;
    if (strncmp(line, prefix, prefix_length) == 0 &&
        line[prefix_length] != '\0')
      return line;
  }
  return NULL;
}

static int refresh_suggestion(void) {
  const char *match;
  size_t prefix_length;
  int old_mark;
  int old_active;

  if (!plugin_enabled || rl_done || history_navigation_active ||
      rl_line_buffer == NULL || rl_point != rl_end || rl_end <= 0 ||
      current_line_is_dismissed()) {
    restore_region_style();
    return 0;
  }

  prefix_length = (size_t)rl_end;
  match = find_history_match(rl_line_buffer, prefix_length);
  if (match == NULL) {
    restore_region_style();
    return 0;
  }

  old_mark = rl_mark;
  old_active = rl_mark_active_p();
  rl_replace_line(match, 0);
  rl_point = (int)prefix_length;
  suggestion_start = rl_point;
  saved_mark = old_mark;
  saved_mark_active = old_active;
  suggestion_active = 1;

  use_suggestion_style();
  rl_mark = rl_end;
  rl_activate_mark();
  rl_keep_mark_active();
  return 1;
}

static int original_preserves_last_function(rl_command_func_t *original) {
  return original == fn_digit_argument || original == fn_vi_arg_digit;
}

static int call_original(rl_command_func_t *original, int count, int key) {
  int result;

  /* Readline records the wrapper as rl_last_func after each dispatch. Restore
   * the semantic command before calling through so repeat-sensitive commands
   * such as history search, menu completion, and yank-pop keep their state. */
  if (rl_last_func != autosuggest_dispatch)
    last_original = rl_last_func;
  rl_last_func = last_original;
  result = original(count, key);
  if (rl_pending_input == 0 && !original_preserves_last_function(original))
    last_original = original;
  return result;
}

static void record_original(rl_command_func_t *original) {
  if (rl_last_func != autosuggest_dispatch)
    last_original = rl_last_func;
  rl_last_func = last_original;
  if (!original_preserves_last_function(original))
    last_original = original;
}

static int is_history_navigation(rl_command_func_t *original) {
  return original == fn_beginning_of_history ||
         original == fn_end_of_history ||
         original == fn_history_search_backward ||
         original == fn_history_search_forward ||
         original == fn_history_substring_search_backward ||
         original == fn_history_substring_search_forward ||
         original == fn_next_history || original == fn_previous_history;
}

static int accept_forward(rl_command_func_t *original, int count, int key) {
  int result = call_original(original, count, key);

  if (rl_point >= rl_end) {
    suggestion_active = 0;
    rl_mark = rl_point;
    rl_deactivate_mark();
    restore_region_style();
  } else {
    suggestion_start = rl_point;
    use_suggestion_style();
    rl_mark = rl_end;
    rl_activate_mark();
    rl_keep_mark_active();
  }
  return result;
}

static int accept_all(rl_command_func_t *original) {
  record_original(original);
  rl_point = rl_end;
  suggestion_active = 0;
  rl_mark = rl_point;
  rl_deactivate_mark();
  restore_region_style();
  return 0;
}

static int accept_to_end(rl_command_func_t *original, int count, int key) {
  int result = call_original(original, count, key);

  suggestion_active = 0;
  rl_mark = rl_point;
  rl_deactivate_mark();
  restore_region_style();
  return result;
}

static int autosuggest_dispatch(int count, int key) {
  Keymap map = rl_executing_keymap != NULL ? rl_executing_keymap
                                           : rl_binding_keymap;
  rl_command_func_t *original = find_original(map, rl_executing_key);
  int navigating_history;
  int dismissing;
  int result;

  if (original == NULL && map != rl_binding_keymap)
    original = find_original(rl_binding_keymap, rl_executing_key);
  if (original == NULL)
    return 0;

  if (suggestion_active && count > 0 && original == fn_forward_char)
    return accept_all(original);
  if (suggestion_active && count > 0 &&
      (original == fn_forward_word || original == fn_shell_forward_word))
    return accept_forward(original, count, key);
  if (suggestion_active && original == fn_end_of_line)
    return accept_to_end(original, count, key);

  dismissing = suggestion_active && original == fn_abort;
  strip_suggestion();
  restore_region_style();
  if (dismissing)
    dismiss_current_line();

  navigating_history = is_history_navigation(original);
  result = call_original(original, count, key);
  if (navigating_history)
    remember_history_navigation();
  else
    finish_non_history_command();

  if (rl_done) {
    clear_dismissed_line();
    clear_history_navigation();
  } else {
    refresh_suggestion();
  }
  return result;
}

static int enable_plugin(void) {
  Keymap roots[] = {emacs_standard_keymap, emacs_meta_keymap,
                    emacs_ctlx_keymap, vi_insertion_keymap,
                    vi_movement_keymap};
  size_t i;

  if (plugin_enabled)
    return EXECUTION_SUCCESS;

  save_region_style();
  fn_abort = rl_named_function("abort");
  fn_beginning_of_history = rl_named_function("beginning-of-history");
  fn_digit_argument = rl_named_function("digit-argument");
  fn_end_of_history = rl_named_function("end-of-history");
  fn_forward_char = rl_named_function("forward-char");
  fn_forward_word = rl_named_function("forward-word");
  fn_history_search_backward =
      rl_named_function("history-search-backward");
  fn_history_search_forward = rl_named_function("history-search-forward");
  fn_history_substring_search_backward =
      rl_named_function("history-substring-search-backward");
  fn_history_substring_search_forward =
      rl_named_function("history-substring-search-forward");
  fn_next_history = rl_named_function("next-history");
  fn_previous_history = rl_named_function("previous-history");
  fn_shell_forward_word = rl_named_function("shell-forward-word");
  fn_end_of_line = rl_named_function("end-of-line");
  fn_vi_arg_digit = rl_named_function("vi-arg-digit");
  last_original = rl_last_func;

  for (i = 0; i < sizeof(roots) / sizeof(roots[0]); ++i) {
    if (!wrap_keymap(roots[i])) {
      restore_keymaps();
      free_region_style();
      fprintf(stderr, "omarchy_autosuggest: out of memory\n");
      return EXECUTION_FAILURE;
    }
  }
  plugin_enabled = 1;
  return EXECUTION_SUCCESS;
}

static int disable_plugin(void) {
  suggestion_active = 0;
  rl_deactivate_mark();
  clear_dismissed_line();
  clear_history_navigation();
  restore_keymaps();
  free_region_style();
  if (rl_last_func == autosuggest_dispatch)
    rl_last_func = last_original;
  last_original = NULL;
  plugin_enabled = 0;
  return EXECUTION_SUCCESS;
}

static int refresh_plugin(void) {
  int was_enabled = plugin_enabled;

  if (was_enabled)
    disable_plugin();
  return enable_plugin();
}

static int set_history_limit(const char *text) {
  char *end;
  long value;

  errno = 0;
  value = strtol(text, &end, 10);
  if (errno != 0 || *text == '\0' || *end != '\0' || value < 1 ||
      value > INT_MAX) {
    fprintf(stderr,
            "omarchy_autosuggest: history limit must be between 1 and %d\n",
            INT_MAX);
    return EXECUTION_FAILURE;
  }
  history_scan_limit = (int)value;
  return EXECUTION_SUCCESS;
}

int omarchy_autosuggest_builtin(WORD_LIST *list) {
  const char *command = list == NULL ? "status" : list->word->word;

  if (strcmp(command, "version") == 0 &&
      (list == NULL || list->next == NULL)) {
    printf("%s\n", OMARCHY_AUTOSUGGEST_VERSION);
    return EXECUTION_SUCCESS;
  }
  if (strcmp(command, "enable") == 0) {
    if (list != NULL && list->next != NULL) {
      fprintf(stderr, "omarchy_autosuggest: enable takes no arguments\n");
      return EX_USAGE;
    }
    return enable_plugin();
  }
  if (strcmp(command, "disable") == 0) {
    if (list != NULL && list->next != NULL) {
      fprintf(stderr, "omarchy_autosuggest: disable takes no arguments\n");
      return EX_USAGE;
    }
    return disable_plugin();
  }
  if (strcmp(command, "refresh") == 0) {
    if (list != NULL && list->next != NULL) {
      fprintf(stderr, "omarchy_autosuggest: refresh takes no arguments\n");
      return EX_USAGE;
    }
    return refresh_plugin();
  }
  if (strcmp(command, "limit") == 0) {
    if (list == NULL || list->next == NULL || list->next->next != NULL) {
      fprintf(stderr, "usage: omarchy_autosuggest limit NUMBER\n");
      return EX_USAGE;
    }
    return set_history_limit(list->next->word->word);
  }
  if (strcmp(command, "status") == 0 &&
      (list == NULL || list->next == NULL)) {
    printf("omarchy_autosuggest %s: %s (history scan limit: %d)\n",
           OMARCHY_AUTOSUGGEST_VERSION,
           plugin_enabled ? "enabled" : "disabled", history_scan_limit);
    return EXECUTION_SUCCESS;
  }

  fprintf(stderr,
          "usage: omarchy_autosuggest "
          "[enable|disable|refresh|status|version|limit NUMBER]\n");
  return EX_USAGE;
}

static char *omarchy_autosuggest_doc[] = {
    "Provide lightweight inline suggestions from Bash history.",
    "",
    "The suggestion is dimmed and italic. Right arrow accepts everything,",
    "Alt-Right accepts a word, Ctrl-Right accepts a shell word, and Ctrl-G",
    "dismisses the current suggestion until the command line changes.",
    "All other editing commands operate on only the text you actually typed.",
    NULL};

struct builtin omarchy_autosuggest_struct = {
    "omarchy_autosuggest",
    omarchy_autosuggest_builtin,
    BUILTIN_ENABLED,
    omarchy_autosuggest_doc,
    "omarchy_autosuggest [enable|disable|refresh|status|version|limit NUMBER]",
    0};
