package mobile

import (
	"archive/zip"
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"

	"github.com/lardan099/hyroute-mobile/internal/geodata"
)

const maxGeoSnapshotSize = 64 << 20
const maxGeoDatabaseSize = 300 << 20

// VPNGeodataSnapshot packages only the databases and categories used at startup.
// An empty result means this snapshot needs no geodata.
func VPNGeodataSnapshot(raw, directory string) ([]byte, error) {
	refs, err := vpnGeodataReferences(raw)
	if err != nil || len(refs) == 0 {
		return nil, err
	}
	var wanted [2][]string
	for _, ref := range refs {
		if !slices.Contains(wanted[ref.kind], ref.name) {
			wanted[ref.kind] = append(wanted[ref.kind], ref.name)
		}
	}
	db := geodata.DB{Dir: directory}
	var compressed geoSnapshotBuffer
	archive := zip.NewWriter(&compressed)
	for _, kind := range []geodata.Kind{geodata.Site, geodata.IP} {
		if len(wanted[kind]) == 0 {
			continue
		}
		entry, err := archive.Create(kind.File())
		if err != nil {
			return nil, err
		}
		if err := db.WriteSubset(kind, wanted[kind], entry); err != nil {
			return nil, err
		}
	}
	if err := archive.Close(); err != nil {
		return nil, err
	}
	return compressed.Bytes(), nil
}

type geoSnapshotBuffer struct{ bytes.Buffer }

func (b *geoSnapshotBuffer) Write(p []byte) (int, error) {
	if len(p) > maxGeoSnapshotSize-b.Len() {
		return 0, errors.New("размер геобаз для запуска превышает 64 МБ")
	}
	return b.Buffer.Write(p)
}

func InstallVPNGeodataSnapshot(data []byte, directory string) error {
	return installVPNGeodata(bytes.NewReader(data), int64(len(data)), directory)
}

func InstallVPNGeodataSnapshotFile(path, directory string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	return installVPNGeodata(file, info.Size(), directory)
}

func installVPNGeodata(source io.ReaderAt, size int64, directory string) error {
	invalid := errors.New("неверный пакет геобаз VPN")
	if size <= 0 || size > maxGeoSnapshotSize {
		return invalid
	}
	archive, err := zip.NewReader(source, size)
	if err != nil || len(archive.File) < 1 || len(archive.File) > 2 {
		return invalid
	}
	seen := make(map[string]bool)
	for _, entry := range archive.File {
		if entry.Name != geodata.Site.File() && entry.Name != geodata.IP.File() ||
			seen[entry.Name] || entry.UncompressedSize64 > maxGeoDatabaseSize {
			return invalid
		}
		seen[entry.Name] = true
		if entry.UncompressedSize64 == 0 {
			// The built-in geoip:private can be used without an IP database.
			if entry.Name != geodata.IP.File() {
				return invalid
			}
			continue
		}
		if err := installVPNGeodataEntry(entry, filepath.Join(directory, entry.Name)); err != nil {
			return err
		}
	}
	return nil
}

func installVPNGeodataEntry(entry *zip.File, path string) error {
	reader, err := entry.Open()
	if err != nil {
		return err
	}
	defer reader.Close()
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	count, copyErr := io.Copy(file, io.LimitReader(reader, int64(entry.UncompressedSize64)+1))
	closeErr := file.Close()
	if copyErr != nil || closeErr != nil {
		return errors.Join(copyErr, closeErr)
	}
	if count != int64(entry.UncompressedSize64) {
		return errors.New("повреждён пакет геобаз VPN")
	}
	return nil
}
