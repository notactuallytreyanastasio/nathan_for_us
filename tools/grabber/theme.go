package main

// framecutTheme makes the desktop app match the Framecut web app: a light,
// warm-neutral (stone) surface with the brand orange as the accent. Colors are
// lifted straight from the web design tokens (tailwind.config.js / app.css):
//
//	background  stone-50   #FAFAF9      brand        #FD4F00
//	text        stone-800  #292524      brand-deep   #C43D00
//	border      stone-300  #D6D3D1      brand-tint   #FFF3ED
//	separator   stone-200  #E7E5E4      hover        stone-100 #F5F5F4

import (
	"image/color"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/theme"
)

type framecutTheme struct{}

var _ fyne.Theme = framecutTheme{}

func rgb(r, g, b uint8) color.Color { return color.NRGBA{R: r, G: g, B: b, A: 0xFF} }

func (framecutTheme) Color(name fyne.ThemeColorName, _ fyne.ThemeVariant) color.Color {
	switch name {
	case theme.ColorNameBackground:
		return rgb(0xFA, 0xFA, 0xF9) // stone-50
	case theme.ColorNameForeground:
		return rgb(0x29, 0x25, 0x24) // stone-800
	case theme.ColorNamePrimary, theme.ColorNameFocus:
		return rgb(0xFD, 0x4F, 0x00) // brand
	case theme.ColorNameHyperlink:
		return rgb(0xC4, 0x3D, 0x00) // brand-deep (readable on light)
	case theme.ColorNameButton, theme.ColorNameInputBackground, theme.ColorNameOverlayBackground, theme.ColorNameMenuBackground:
		return color.White
	case theme.ColorNameInputBorder:
		return rgb(0xD6, 0xD3, 0xD1) // stone-300
	case theme.ColorNameSeparator:
		return rgb(0xE7, 0xE5, 0xE4) // stone-200
	case theme.ColorNamePlaceHolder, theme.ColorNameDisabled:
		return rgb(0xA8, 0xA2, 0x9E) // stone-400
	case theme.ColorNameHover:
		return rgb(0xF5, 0xF5, 0xF4) // stone-100
	case theme.ColorNameSelection:
		return rgb(0xFF, 0xF3, 0xED) // brand-tint
	case theme.ColorNameShadow:
		return color.NRGBA{A: 0x22}
	default:
		// Force the light variant of the default theme for anything unhandled.
		return theme.DefaultTheme().Color(name, theme.VariantLight)
	}
}

func (framecutTheme) Font(s fyne.TextStyle) fyne.Resource { return theme.DefaultTheme().Font(s) }

func (framecutTheme) Icon(n fyne.ThemeIconName) fyne.Resource {
	return theme.DefaultTheme().Icon(n)
}

func (framecutTheme) Size(n fyne.ThemeSizeName) float32 { return theme.DefaultTheme().Size(n) }
