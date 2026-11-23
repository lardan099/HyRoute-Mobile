package geodata

import (
	"encoding/binary"
	"io"
	"strings"
)

// WriteSubset copies the requested protobuf category records into a database
// of the same kind. GeoSite attributes remain available for rule evaluation.
func (db *DB) WriteSubset(kind Kind, names []string, dst io.Writer) error {
	builtinPrivate := kind == IP && len(names) == 1 && names[0] == "private"
	file, err := openRead(db.path(kind))
	if err != nil {
		if builtinPrivate {
			return nil
		}
		return err
	}
	defer file.Close()
	index, err := indexReader(file)
	if err != nil {
		if builtinPrivate {
			return nil
		}
		return err
	}
	written := make(map[string]bool)
	for _, name := range names {
		name = strings.ToLower(strings.TrimSpace(name))
		if kind == Site {
			name, _ = splitAttrs(name)
		}
		if written[name] {
			continue
		}
		item, ok := index[name]
		if !ok {
			if kind == IP && name == "private" {
				continue
			}
			return &UnknownError{Kind: kind, Name: name}
		}
		header := binary.AppendUvarint([]byte{0x0a}, uint64(item.n))
		if _, err := dst.Write(header); err != nil {
			return err
		}
		if _, err := io.CopyN(dst, io.NewSectionReader(file, item.off, int64(item.n)), int64(item.n)); err != nil {
			return err
		}
		written[name] = true
	}
	return nil
}
