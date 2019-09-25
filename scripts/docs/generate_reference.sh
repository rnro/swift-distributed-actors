#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift Distributed Actors open source project
##
## Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##


set -e

declare -r my_path="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
declare -r root_path="$my_path/../.."

short_version=$(git describe --abbrev=0 --tags 2> /dev/null || echo "0.0.0")
long_version=$(git describe            --tags 2> /dev/null || echo "0.0.0")
if [[ "$short_version" == "$long_version" ]]; then
  version="${short_version}"
else
  version="${short_version}-dev"
fi
echo "Project version: ${version}"

# run asciidoctor
if ! command -v asciidoctor > /dev/null; then
  gem install asciidoctor -v 1.5.8 --no-ri --no-rdoc
  gem install asciidoctor-diagram -v 1.5.8 --no-ri --no-rdoc
fi

declare -r target_dir="$root_path/.build/docs/reference/$version"
mkdir -p "$target_dir"

#  -r $root_path/scripts/asciidoctor/pygments_init.rb \
asciidoctor \
  -r $root_path/scripts/asciidoctor/multipage_html5_converter.rb \
  -r $root_path/scripts/asciidoctor/swift_api_reference.rb \
  -r $root_path/scripts/asciidoctor/nio_api_reference.rb \
  -r $root_path/scripts/asciidoctor/api_reference.rb \
  -r asciidoctor-diagram \
  -b multipage_html5 \
  -D $target_dir \
  $root_path/Docs/index.adoc

cp -r $root_path/Docs/images $target_dir/
cp -r $root_path/Docs/stylesheets $target_dir/

echo "Docs generated: $target_dir/index.html"
