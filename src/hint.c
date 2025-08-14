/*
 * warpd - A modal keyboard-driven pointing system.
 *
 * © 2019 Raheman Vaiya (see: LICENSE).
 */

#include "warpd.h"

struct hint *hints;
struct hint matched[MAX_HINTS];
static size_t matched_indices[MAX_HINTS];

static size_t nr_hints;
static size_t nr_matched;

char last_selected_hint[32];

static void filter(screen_t scr, const char *s)
{
	size_t i;

	nr_matched = 0;
	for (i = 0; i < nr_hints; i++) {
		if (strstr(hints[i].label, s) == hints[i].label)
			matched[nr_matched++] = hints[i];
	}

	platform->screen_clear(scr);
	platform->hint_draw(scr, matched, nr_matched);
	platform->commit();
}

static void get_hint_size(screen_t scr, int *w, int *h)
{
	int sw, sh;

	platform->screen_get_dimensions(scr, &sw, &sh);

	if (sw < sh) {
		int tmp = sw;
		sw = sh;
		sh = tmp;
	}

	*w = (sw * config_get_int("hint_size")) / 1000;
	*h = (sh * config_get_int("hint_size")) / 1000;
}

static int hint_screen_x[MAX_HINTS];
static int hint_screen_y[MAX_HINTS];

static size_t generate_multiscreen_hints(struct hint *hints)
{
	screen_t screens[MAX_SCREENS];
	size_t screen_count;
	const char *chars = config_get("hint_chars");
	size_t chars_len = strlen(chars);
	int w, h;
	size_t total_hints = 0;

	platform->screen_list(screens, &screen_count);

	// Calculate hints per screen - use first screen as reference
	get_hint_size(screens[0], &w, &h);

	int nc = chars_len;
	int nr = chars_len;

	size_t hints_per_screen = nc * nr;
	size_t total_positions = hints_per_screen * screen_count;

	// Generate enough unique labels to cover all screens
	char labels[MAX_HINTS][4];
	size_t label_count = 0;

	// For multi-screen or if we need more than 676 hints, use 3-character
	// labels for consistency
	if (screen_count > 1 || total_positions > 676) {
		// Generate 3-character labels for all hints
		for (size_t i = 0; i < chars_len && label_count < MAX_HINTS &&
				   label_count < total_positions;
		     i++) {
			for (size_t j = 0;
			     j < chars_len && label_count < MAX_HINTS &&
			     label_count < total_positions;
			     j++) {
				for (size_t k = 0;
				     k < chars_len && label_count < MAX_HINTS &&
				     label_count < total_positions;
				     k++) {
					labels[label_count][0] = chars[i];
					labels[label_count][1] = chars[j];
					labels[label_count][2] = chars[k];
					labels[label_count][3] = 0;
					label_count++;
				}
			}
		}
	} else {
		// Generate 2-character labels for single screen with <= 676
		// hints
		for (size_t i = 0; i < chars_len && label_count < MAX_HINTS;
		     i++) {
			for (size_t j = 0;
			     j < chars_len && label_count < MAX_HINTS; j++) {
				labels[label_count][0] = chars[i];
				labels[label_count][1] = chars[j];
				labels[label_count][2] = 0;
				label_count++;
			}
		}
	}

	// Distribute hints across screens
	size_t label_index = 0;
	for (size_t screen_idx = 0;
	     screen_idx < screen_count && total_hints < MAX_HINTS;
	     screen_idx++) {
		int sw, sh;
		platform->screen_get_dimensions(screens[screen_idx], &sw, &sh);
		get_hint_size(screens[screen_idx], &w, &h);

		int colgap = sw / nc - w;
		int rowgap = sh / nr - h;

		int x_offset = colgap / 2;
		int y_offset = rowgap / 2;

		int y = y_offset;
		for (int i = 0; i < nr && label_index < label_count &&
				total_hints < MAX_HINTS;
		     i++) {
			int x = x_offset;
			for (int j = 0; j < nc && label_index < label_count &&
					total_hints < MAX_HINTS;
			     j++) {
				hints[total_hints].x = x;
				hints[total_hints].y = y;
				hints[total_hints].w = w;
				hints[total_hints].h = h;
				strcpy(hints[total_hints].label,
				       labels[label_index]);
				// Store screen index instead of coordinates
				hint_screen_x[total_hints] = screen_idx;
				hint_screen_y[total_hints] = 0;

				total_hints++;
				label_index++;
				x += colgap + w;
			}
			y += rowgap + h;
		}
	}

	return total_hints;
}

static void draw_hints_on_all_screens(const char *filter_str)
{
	screen_t screens[MAX_SCREENS];
	size_t screen_count;
	platform->screen_list(screens, &screen_count);

	// Clear all screens first
	for (size_t i = 0; i < screen_count; i++) {
		platform->screen_clear(screens[i]);
	}

	// Group hints by screen and draw them
	for (size_t i = 0; i < screen_count; i++) {
		struct hint screen_hints[MAX_HINTS];
		size_t screen_hint_count = 0;

		for (size_t j = 0; j < nr_hints; j++) {
			if (hint_screen_x[j] == (int)i) {
				if (filter_str[0] == 0 ||
				    strncmp(hints[j].label, filter_str,
					    strlen(filter_str)) == 0) {
					screen_hints[screen_hint_count++] =
					    hints[j];
				}
			}
		}

		if (screen_hint_count > 0) {
			platform->hint_draw(screens[i], screen_hints,
					    screen_hint_count);
		}
	}

	// Update matched hints for global matching
	nr_matched = 0;
	for (size_t i = 0; i < nr_hints && nr_matched < MAX_HINTS; i++) {
		if (filter_str[0] == 0 || strncmp(hints[i].label, filter_str,
						  strlen(filter_str)) == 0) {
			matched[nr_matched] = hints[i];
			matched_indices[nr_matched] = i;
			nr_matched++;
		}
	}

	platform->commit();
}

static int hint_selection_multiscreen(struct hint *_hints, size_t _nr_hints)
{
	hints = _hints;
	nr_hints = _nr_hints;

	draw_hints_on_all_screens("");

	int rc = 0;
	char buf[32] = {0};
	platform->input_grab_keyboard();

	platform->mouse_hide();

	const char *keys[] = {
	    "hint_exit",
	    "hint_undo_all",
	    "hint_undo",
	};

	config_input_whitelist(keys, sizeof keys / sizeof keys[0]);

	while (1) {
		struct input_event *ev;
		ssize_t len;

		ev = platform->input_next_event(0);

		if (!ev->pressed)
			continue;

		len = strlen(buf);

		if (config_input_match(ev, "hint_exit")) {
			rc = -1;
			break;
		} else if (config_input_match(ev, "hint_undo_all")) {
			buf[0] = 0;
		} else if (config_input_match(ev, "hint_undo")) {
			if (len)
				buf[len - 1] = 0;
		} else {
			const char *name = input_event_tostr(ev);

			if (!name || name[1])
				continue;

			buf[len++] = name[0];
			buf[len] = 0;
		}

		draw_hints_on_all_screens(buf);

		if (nr_matched == 1) {
			int nx, ny;
			struct hint *h = &matched[0];
			screen_t target_screen = NULL;

			// Find the target screen by index
			screen_t screens[MAX_SCREENS];
			size_t screen_count;
			platform->screen_list(screens, &screen_count);

			size_t hint_index = matched_indices[0];

			if (hint_index >= MAX_HINTS) {
				break;
			}

			if (hint_screen_x[hint_index] < (int)screen_count) {
				target_screen =
				    screens[hint_screen_x[hint_index]];
			}

			if (target_screen == NULL) {
				break;
			}

			for (size_t i = 0; i < screen_count; i++) {
				platform->screen_clear(screens[i]);
			}

			nx = h->x + h->w / 2;
			ny = h->y + h->h / 2;

			platform->mouse_move(target_screen, nx + 1, ny + 1);
			platform->mouse_move(target_screen, nx, ny);
			strcpy(last_selected_hint, buf);
			break;
		} else if (nr_matched == 0) {
			// Don't exit - just continue waiting for more input
			// The user might type more characters to match a hint
		}
	}

	platform->input_ungrab_keyboard();

	screen_t screens[MAX_SCREENS];
	size_t screen_count;
	platform->screen_list(screens, &screen_count);

	for (size_t i = 0; i < screen_count; i++) {
		platform->screen_clear(screens[i]);
	}

	platform->mouse_show();
	platform->commit();
	return rc;
}

static int hint_selection(screen_t scr, struct hint *_hints, size_t _nr_hints)
{
	hints = _hints;
	nr_hints = _nr_hints;

	filter(scr, "");

	int rc = 0;
	char buf[32] = {0};
	platform->input_grab_keyboard();

	platform->mouse_hide();

	const char *keys[] = {
	    "hint_exit",
	    "hint_undo_all",
	    "hint_undo",
	};

	config_input_whitelist(keys, sizeof keys / sizeof keys[0]);

	while (1) {
		struct input_event *ev;
		ssize_t len;

		ev = platform->input_next_event(0);

		if (!ev->pressed)
			continue;

		len = strlen(buf);

		if (config_input_match(ev, "hint_exit")) {
			rc = -1;
			break;
		} else if (config_input_match(ev, "hint_undo_all")) {
			buf[0] = 0;
		} else if (config_input_match(ev, "hint_undo")) {
			if (len)
				buf[len - 1] = 0;
		} else {
			const char *name = input_event_tostr(ev);

			if (!name || name[1])
				continue;

			buf[len++] = name[0];
		}

		filter(scr, buf);

		if (nr_matched == 1) {
			int nx, ny;
			struct hint *h = &matched[0];

			platform->screen_clear(scr);

			nx = h->x + h->w / 2;
			ny = h->y + h->h / 2;

			/*
			 * Wiggle the cursor a single pixel to accommodate
			 * text selection widgets which don't like spontaneous
			 * cursor warping.
			 */
			platform->mouse_move(scr, nx + 1, ny + 1);

			platform->mouse_move(scr, nx, ny);
			strcpy(last_selected_hint, buf);
			break;
		} else if (nr_matched == 0) {
			break;
		}
	}

	platform->input_ungrab_keyboard();
	platform->screen_clear(scr);
	platform->mouse_show();

	platform->commit();
	return rc;
}

static int sift()
{
	int gap = config_get_int("hint2_gap_size");
	int hint_sz = config_get_int("hint2_size");

	const char *chars = config_get("hint2_chars");
	size_t chars_len = strlen(chars);

	int grid_sz = config_get_int("hint2_grid_size");

	int x, y;
	int sh, sw;

	int col;
	int row;
	size_t n = 0;
	screen_t scr;

	struct hint hints[MAX_HINTS];

	platform->mouse_get_position(&scr, &x, &y);
	platform->screen_get_dimensions(scr, &sw, &sh);

	gap = (gap * sh) / 1000;
	hint_sz = (hint_sz * sh) / 1000;

	x -= ((hint_sz + (gap - 1)) * grid_sz) / 2;
	y -= ((hint_sz + (gap - 1)) * grid_sz) / 2;

	for (col = 0; col < grid_sz; col++)
		for (row = 0; row < grid_sz; row++) {
			size_t idx = (row * grid_sz) + col;

			if (idx < chars_len) {
				hints[n].x = x + (hint_sz + gap) * col;
				hints[n].y = y + (hint_sz + gap) * row;

				hints[n].w = hint_sz;
				hints[n].h = hint_sz;
				hints[n].label[0] = chars[idx];
				hints[n].label[1] = 0;

				n++;
			}
		}

	return hint_selection(scr, hints, n);
}

void init_hints()
{
	platform->init_hint(
	    config_get("hint_bgcolor"), config_get("hint_fgcolor"),
	    config_get_int("hint_border_radius"), config_get("hint_font"));
}

int hintspec_mode()
{
	screen_t scr;
	int sw, sh;
	int w, h;

	int n = 0;
	struct hint hints[MAX_HINTS];

	platform->mouse_get_position(&scr, NULL, NULL);
	platform->screen_get_dimensions(scr, &sw, &sh);

	get_hint_size(scr, &w, &h);

	while (scanf("%15s %d %d", hints[n].label, &hints[n].x, &hints[n].y) ==
	       3) {

		hints[n].w = w;
		hints[n].h = h;
		hints[n].x -= w / 2;
		hints[n].y -= h / 2;

		n++;
	}

	return hint_selection(scr, hints, n);
}

int full_hint_mode(int second_pass)
{
	int mx, my;
	screen_t scr;
	struct hint hints[MAX_HINTS];

	platform->mouse_get_position(&scr, &mx, &my);
	hist_add(mx, my);

	nr_hints = generate_multiscreen_hints(hints);

	if (hint_selection_multiscreen(hints, nr_hints))
		return -1;

	if (second_pass)
		return sift();
	else
		return 0;
}

int history_hint_mode()
{
	struct hint hints[MAX_HINTS];
	struct histfile_ent *ents;
	screen_t scr;
	int w, h;
	int sw, sh;
	size_t n, i;

	platform->mouse_get_position(&scr, NULL, NULL);
	platform->screen_get_dimensions(scr, &sw, &sh);

	n = histfile_read(&ents);

	get_hint_size(scr, &w, &h);

	for (i = 0; i < n; i++) {
		hints[i].w = w;
		hints[i].h = h;

		hints[i].x = ents[i].x - w / 2;
		hints[i].y = ents[i].y - h / 2;

		hints[i].label[0] = 'a' + i;
		hints[i].label[1] = 0;
	}

	return hint_selection(scr, hints, n);
}
