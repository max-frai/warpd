#include "macos.h"

static float border_radius;

static NSColor *bgColor;
static NSColor *fgColor;
const char *font;

static void draw_modern_hint(struct screen *scr, struct hint *h)
{
	// Save graphics state
	NSGraphicsContext *context = [NSGraphicsContext currentContext];
	[context saveGraphicsState];

	// Convert coordinates to macOS LLO and make hints smaller with padding
	float padding = 4;
	float x = h->x + padding;
	float y = scr->h - h->y - h->h + padding;
	float w = h->w - (padding * 2);
	float h_val = h->h - (padding * 2);

	// Create main hint path with modern radius
	float modernRadius = border_radius;
	NSBezierPath *hintPath = [NSBezierPath
		bezierPathWithRoundedRect:NSMakeRect(x, y, w, h_val)
		xRadius:modernRadius
		yRadius:modernRadius];

	// Create subtle outer glow effect
	for (int i = 3; i >= 0; i--) {
		float glowAlpha = 0.06 * (3 - i) / 3.0;
		NSBezierPath *glowPath = [NSBezierPath
			bezierPathWithRoundedRect:NSMakeRect(x - i, y - i, w + 2*i, h_val + 2*i)
			xRadius:modernRadius + i
			yRadius:modernRadius + i];

		[[NSColor colorWithCalibratedRed:0.3 green:0.6 blue:1.0 alpha:glowAlpha] setFill];
		[glowPath fill];
	}

	// Add subtle drop shadow
	NSShadow *shadow = [[NSShadow alloc] init];
	[shadow setShadowColor:[NSColor colorWithCalibratedRed:0.0 green:0.0 blue:0.0 alpha:0.3]];
	[shadow setShadowOffset:NSMakeSize(0, -2)];
	[shadow setShadowBlurRadius:4.0];
	[shadow set];

	// Create sophisticated gradient with glassmorphism effect
	NSColor *topColor = [NSColor colorWithCalibratedRed:0.95 green:0.95 blue:0.98 alpha:0.85];
	NSColor *bottomColor = [NSColor colorWithCalibratedRed:0.88 green:0.88 blue:0.94 alpha:0.75];

	NSGradient *backgroundGradient = [[NSGradient alloc]
		initWithStartingColor:topColor
		endingColor:bottomColor];

	// Fill with gradient
	[backgroundGradient drawInBezierPath:hintPath angle:90.0];

	// Clear shadow for border
	[shadow setShadowColor:[NSColor clearColor]];
	[shadow set];

	// Add subtle inner shadow for depth
	NSBezierPath *innerPath = [NSBezierPath
		bezierPathWithRoundedRect:NSMakeRect(x + 1, y + 1, w - 2, h_val - 2)
		xRadius:modernRadius - 1
		yRadius:modernRadius - 1];

	// Create inner highlight
	NSGradient *innerGradient = [[NSGradient alloc]
		initWithStartingColor:[NSColor colorWithCalibratedRed:1.0 green:1.0 blue:1.0 alpha:0.4]
		endingColor:[NSColor colorWithCalibratedRed:1.0 green:1.0 blue:1.0 alpha:0.0]];

	[innerGradient drawInBezierPath:innerPath angle:90.0];

	// Add modern border with subtle color
	[[NSColor colorWithCalibratedRed:0.7 green:0.7 blue:0.8 alpha:0.8] setStroke];
	[hintPath setLineWidth:1.5];
	[hintPath stroke];

	// Add inner bright border for premium look
	[[NSColor colorWithCalibratedRed:1.0 green:1.0 blue:1.0 alpha:0.6] setStroke];
	[innerPath setLineWidth:0.5];
	[innerPath stroke];

	// Modern text rendering with sharp text
	int fontSize = h_val * 0.65;
	if (fontSize < 12) fontSize = 12;
	if (fontSize > 20) fontSize = 20;

	NSFont *modernFont = [NSFont fontWithName:@"SF Pro Display" size:fontSize];
	if (!modernFont) {
		modernFont = [NSFont fontWithName:@"Helvetica Neue" size:fontSize];
	}
	if (!modernFont) {
		modernFont = [NSFont systemFontOfSize:fontSize weight:NSFontWeightSemibold];
	}

	// Sharp text without shadow
	NSDictionary *textAttrs = @{
		NSFontAttributeName : modernFont,
		NSForegroundColorAttributeName : [NSColor colorWithCalibratedRed:0.15 green:0.15 blue:0.25 alpha:1.0],
	};

	// Draw centered text
	NSString *labelStr = [NSString stringWithUTF8String:h->label];
	CGSize textSize = [labelStr sizeWithAttributes:textAttrs];

	float textX = x + (w - textSize.width) / 2;
	float textY = y + (h_val - textSize.height) / 2;

	[labelStr drawAtPoint:NSMakePoint(textX, textY) withAttributes:textAttrs];

	// Restore graphics state
	[context restoreGraphicsState];
}

static void draw_hook(void *arg, NSView *view)
{
	size_t i;
	struct screen *scr = arg;

	for (i = 0; i < scr->nr_hints; i++) {
		struct hint *h = &scr->hints[i];
		draw_modern_hint(scr, h);
	}
}

void osx_hint_draw(struct screen *scr, struct hint *hints, size_t n)
{


	scr->nr_hints = n;
	memcpy(scr->hints, hints, sizeof(struct hint)*n);

	window_register_draw_hook(scr->overlay, draw_hook, scr);
}

void osx_init_hint(const char *bg, const char *fg, int _border_radius,
	       const char *font_family)
{
	bgColor = nscolor_from_hex(bg);
	fgColor = nscolor_from_hex(fg);

	border_radius = (float)_border_radius;
	font = font_family;
}
